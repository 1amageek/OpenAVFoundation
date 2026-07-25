import Synchronization

final class CaptureSessionOwner: Sendable {}

enum CaptureSessionPhase: Sendable {
    case idle
    case starting
    case running
    case stopping
    case cleanupRequired
}

struct CaptureSessionGraph: Sendable {
    var inputs: [CaptureInputReference] = []
    var outputs: [CaptureOutputReference] = []
    var connections: [AVCaptureConnection] = []
}

struct CaptureInputReference: Sendable {
    // AVCaptureInput is subclassable, so checked conformance is impossible.
    // This wrapper is the graph's only strong input-reference Sendable
    // boundary. The retained instance's framework-owned mutable state is
    // independently Mutex-protected, and the wrapper never mutates the
    // reference.
    nonisolated(unsafe) let value: AVCaptureInput
}

struct CaptureOutputReference: Sendable {
    // AVCaptureOutput is subclassable, so checked conformance is impossible.
    // Graph, connection, and queued-delivery values share this immutable
    // wrapper instead of declaring additional unsafe reference boundaries.
    // Framework-owned output state remains Mutex-protected.
    nonisolated(unsafe) let value: AVCaptureOutput
}

struct CaptureSessionStartPlan: Sendable {
    let device: AVCaptureDevice
    let deviceID: CaptureDeviceID
    let capabilityRevision: UInt64
    let opener: CaptureDeviceHandleOpener
    let routes: [CaptureSessionOutputRoute]
    let videoConnectionConfiguration: CaptureVideoConnectionConfiguration
}

struct CaptureSessionOutputRoute: Sendable {
    let delivery: VideoOutputDelivery
    let connection: AVCaptureConnection
}

final class AVCaptureSessionGraphStorage: Sendable {
    private struct State: Sendable {
        var committed = CaptureSessionGraph()
        var draft: CaptureSessionGraph?
        var phase = CaptureSessionPhase.idle
        var operationInProgress = false
    }

    private let owner = CaptureSessionOwner()
    private let state = Mutex(State())

    private var ownerID: ObjectIdentifier {
        ObjectIdentifier(owner)
    }

    deinit {
        let graph = state.withLock { state in state.committed }
        // Release nested object ownership only after leaving the graph lock.
        for output in graph.outputs {
            output.value.replaceConnections([])
            output.value.releaseOwnership(by: ownerID)
        }
        for input in graph.inputs {
            input.value.releaseOwnership(by: ownerID)
        }
    }

    var inputs: [AVCaptureInput] {
        state.withLock { state in
            state.committed.inputs.map { reference in
                reference.value
            }
        }
    }

    var outputs: [AVCaptureOutput] {
        state.withLock { state in
            state.committed.outputs.map { reference in
                reference.value
            }
        }
    }

    var connections: [AVCaptureConnection] {
        state.withLock { state in state.committed.connections }
    }

    var isRunning: Bool {
        state.withLock { state in state.phase == .running }
    }

    func beginConfiguration() throws(AVCaptureSessionError) {
        try state.withLock { state throws(AVCaptureSessionError) in
            guard !state.operationInProgress else {
                throw .sessionBusy
            }
            guard state.phase == .idle else {
                throw .configurationWhileRunningUnsupported
            }
            guard state.draft == nil else {
                throw .configurationAlreadyActive
            }
            state.draft = state.committed
        }
    }

    func commitConfiguration() throws(AVCaptureSessionError) {
        let graphs = try state.withLock {
            state throws(AVCaptureSessionError)
                -> (draft: CaptureSessionGraph, committed: CaptureSessionGraph) in
            guard !state.operationInProgress else {
                throw .sessionBusy
            }
            guard let draft = state.draft else {
                throw .configurationNotActive
            }
            state.operationInProgress = true
            // Preserve the existing contract: every commit attempt consumes
            // the draft, including validation and ownership failures.
            state.draft = nil
            return (draft, state.committed)
        }

        let validated: CaptureSessionGraph
        do {
            validated = try Self.validatedCompleteGraph(graphs.draft)
        } catch {
            finishOperation()
            throw error
        }

        var claimedInputs: [AVCaptureInput] = []
        for input in validated.inputs
        where !Self.containsIdentity(graphs.committed.inputs, input) {
            guard input.value.claimOwnership(by: ownerID) else {
                Self.releaseInputs(claimedInputs, ownerID: ownerID)
                finishOperation()
                throw .inputOwnedByAnotherSession
            }
            claimedInputs.append(input.value)
        }

        var claimedOutputs: [AVCaptureOutput] = []
        for output in validated.outputs
        where !Self.containsIdentity(graphs.committed.outputs, output) {
            guard output.value.claimOwnership(by: ownerID) else {
                Self.releaseOutputs(claimedOutputs, ownerID: ownerID)
                Self.releaseInputs(claimedInputs, ownerID: ownerID)
                finishOperation()
                throw .outputOwnedByAnotherSession
            }
            claimedOutputs.append(output.value)
        }

        // Input/output locks and connection publication occur with the graph
        // state lock released. operationInProgress prevents a second graph
        // mutation from replacing this transaction. Each public accessor is a
        // synchronized snapshot, but separate session/output accessor calls do
        // not form one cross-object linearizable read.
        Self.synchronizeOutputConnections(validated)
        state.withLock { state in
            state.committed = validated
            state.operationInProgress = false
        }

        for input in graphs.committed.inputs
        where !Self.containsIdentity(validated.inputs, input) {
            input.value.releaseOwnership(by: ownerID)
        }
        for output in graphs.committed.outputs
        where !Self.containsIdentity(validated.outputs, output) {
            output.value.replaceConnections([])
            output.value.releaseOwnership(by: ownerID)
        }
    }

    func canAddInput(_ input: AVCaptureInput) -> Bool {
        let graph = state.withLock { state -> CaptureSessionGraph? in
            guard !state.operationInProgress, state.phase == .idle else {
                return nil
            }
            return state.draft ?? state.committed
        }
        guard let graph,
              input is AVCaptureDeviceInput,
              input.ports.contains(where: {
                  $0.mediaType == .video && $0.isEnabled
              })
        else {
            return false
        }
        return graph.inputs.isEmpty
            && !Self.containsIdentity(graph.inputs, input)
            && input.canBeOwned(by: ownerID)
    }

    func addInput(
        _ input: AVCaptureInput
    ) throws(AVCaptureSessionError) {
        guard input is AVCaptureDeviceInput,
              input.ports.contains(where: {
                  $0.mediaType == .video && $0.isEnabled
              })
        else {
            throw .unsupportedInput
        }

        let reserved = try reserveGraphMutation()
        guard !Self.containsIdentity(reserved.graph.inputs, input) else {
            finishOperation()
            throw .duplicateInput
        }
        guard reserved.graph.inputs.isEmpty else {
            finishOperation()
            throw .inputLimitReached
        }

        if reserved.usesDraft {
            guard input.canBeOwned(by: ownerID) else {
                finishOperation()
                throw .inputOwnedByAnotherSession
            }
        } else {
            guard input.claimOwnership(by: ownerID) else {
                finishOperation()
                throw .inputOwnedByAnotherSession
            }
        }

        var graph = reserved.graph
        graph.inputs.append(CaptureInputReference(value: input))
        if !reserved.usesDraft {
            graph = Self.graphWithAutomaticConnections(graph)
            Self.synchronizeOutputConnections(graph)
        }
        finishGraphMutation(graph, usesDraft: reserved.usesDraft)
    }

    func removeInput(
        _ input: AVCaptureInput
    ) throws(AVCaptureSessionError) {
        let reserved = try reserveGraphMutation()
        var graph = reserved.graph
        let existed = Self.containsIdentity(graph.inputs, input)
        graph.inputs.removeAll { $0.value === input }
        graph.connections = []
        if !reserved.usesDraft {
            Self.synchronizeOutputConnections(graph)
        }
        finishGraphMutation(graph, usesDraft: reserved.usesDraft)
        if existed && !reserved.usesDraft {
            input.releaseOwnership(by: ownerID)
        }
    }

    func canAddOutput(_ output: AVCaptureOutput) -> Bool {
        let graph = state.withLock { state -> CaptureSessionGraph? in
            guard !state.operationInProgress, state.phase == .idle else {
                return nil
            }
            return state.draft ?? state.committed
        }
        guard let graph, output is AVCaptureVideoDataOutput else {
            return false
        }
        return !Self.containsIdentity(graph.outputs, output)
            && output.canBeOwned(by: ownerID)
    }

    func addOutput(
        _ output: AVCaptureOutput
    ) throws(AVCaptureSessionError) {
        guard output is AVCaptureVideoDataOutput else {
            throw .unsupportedOutput
        }
        let reserved = try reserveGraphMutation()
        guard !Self.containsIdentity(reserved.graph.outputs, output) else {
            finishOperation()
            throw .duplicateOutput
        }

        if reserved.usesDraft {
            guard output.canBeOwned(by: ownerID) else {
                finishOperation()
                throw .outputOwnedByAnotherSession
            }
        } else {
            guard output.claimOwnership(by: ownerID) else {
                finishOperation()
                throw .outputOwnedByAnotherSession
            }
        }

        var graph = reserved.graph
        graph.outputs.append(CaptureOutputReference(value: output))
        if !reserved.usesDraft {
            graph = Self.graphWithAutomaticConnections(graph)
            Self.synchronizeOutputConnections(graph)
        }
        finishGraphMutation(graph, usesDraft: reserved.usesDraft)
    }

    func removeOutput(
        _ output: AVCaptureOutput
    ) throws(AVCaptureSessionError) {
        let reserved = try reserveGraphMutation()
        var graph = reserved.graph
        let existed = Self.containsIdentity(graph.outputs, output)
        graph.outputs.removeAll { $0.value === output }
        graph = Self.graphWithAutomaticConnections(graph)
        if !reserved.usesDraft {
            Self.synchronizeOutputConnections(graph)
        }
        finishGraphMutation(graph, usesDraft: reserved.usesDraft)
        if existed && !reserved.usesDraft {
            output.replaceConnections([])
            output.releaseOwnership(by: ownerID)
        }
    }

    func prepareToStart()
        throws(AVCaptureSessionError) -> CaptureSessionStartPlan
    {
        let graph = try state.withLock {
            state throws(AVCaptureSessionError) -> CaptureSessionGraph in
            guard !state.operationInProgress else {
                throw .sessionBusy
            }
            guard state.draft == nil else {
                throw .configurationInProgress
            }
            guard state.phase == .idle else {
                throw .sessionBusy
            }
            state.operationInProgress = true
            return state.committed
        }

        let validated: CaptureSessionGraph
        do {
            validated = try Self.validatedCompleteGraph(graph)
        } catch {
            finishOperation()
            throw error
        }
        Self.synchronizeOutputConnections(validated)

        guard let input =
                validated.inputs[0].value as? AVCaptureDeviceInput
        else {
            finishOperation()
            throw .unsupportedInput
        }
        var routes: [CaptureSessionOutputRoute] = []
        routes.reserveCapacity(validated.connections.count)
        for connection in validated.connections {
            guard let output =
                    connection.output as? AVCaptureVideoDataOutput else {
                finishOperation()
                throw .unsupportedOutput
            }
            routes.append(
                CaptureSessionOutputRoute(
                    delivery: output.deliveryEndpoint,
                    connection: connection
                )
            )
        }

        let connectionConfiguration =
            validated.connections[0].videoConnectionConfiguration
        guard validated.connections.dropFirst().allSatisfy({
            $0.videoConnectionConfiguration == connectionConfiguration
        }) else {
            finishOperation()
            throw .incompatibleVideoConnectionConfigurations
        }

        state.withLock { state in
            state.committed = validated
            state.phase = .starting
            state.operationInProgress = false
        }
        return CaptureSessionStartPlan(
            device: input.device,
            deviceID: input.device.captureDeviceID,
            capabilityRevision: input.device.descriptor.capabilityRevision,
            opener: input.device.handleOpener,
            routes: routes,
            videoConnectionConfiguration: connectionConfiguration
        )
    }

    private func reserveGraphMutation()
        throws(AVCaptureSessionError)
        -> (graph: CaptureSessionGraph, usesDraft: Bool)
    {
        try state.withLock { state throws(AVCaptureSessionError) in
            guard !state.operationInProgress else {
                throw .sessionBusy
            }
            guard state.phase == .idle else {
                throw .configurationWhileRunningUnsupported
            }
            state.operationInProgress = true
            if let draft = state.draft {
                return (draft, true)
            }
            return (state.committed, false)
        }
    }

    private func finishGraphMutation(
        _ graph: CaptureSessionGraph,
        usesDraft: Bool
    ) {
        state.withLock { state in
            if usesDraft {
                state.draft = graph
            } else {
                state.committed = graph
            }
            state.operationInProgress = false
        }
    }

    private func finishOperation() {
        state.withLock { state in
            state.operationInProgress = false
        }
    }

    func finishStart(cleanupRequired: Bool) {
        state.withLock { state in
            state.phase = cleanupRequired ? .cleanupRequired : .idle
        }
    }

    func finishStartSuccessfully() {
        state.withLock { state in state.phase = .running }
    }

    func prepareToStop() throws(AVCaptureSessionError) -> Bool {
        try state.withLock { state throws(AVCaptureSessionError) in
            guard !state.operationInProgress else {
                throw .sessionBusy
            }
            switch state.phase {
            case .idle:
                return false
            case .running, .cleanupRequired:
                state.phase = .stopping
                return true
            case .starting, .stopping:
                throw .sessionBusy
            }
        }
    }

    func finishStop(cleanupRequired: Bool) {
        state.withLock { state in
            state.phase = cleanupRequired ? .cleanupRequired : .idle
        }
    }

    private static func validatedCompleteGraph(
        _ graph: CaptureSessionGraph
    ) throws(AVCaptureSessionError) -> CaptureSessionGraph {
        guard !graph.inputs.isEmpty else {
            throw .missingInput
        }
        guard graph.inputs.count == 1 else {
            throw .inputLimitReached
        }
        guard !graph.outputs.isEmpty else {
            throw .missingOutput
        }
        guard graph.inputs[0].value is AVCaptureDeviceInput else {
            throw .unsupportedInput
        }
        for output in graph.outputs {
            guard output.value is AVCaptureVideoDataOutput else {
                throw .unsupportedOutput
            }
        }
        let videoPorts = graph.inputs[0].value.ports.filter {
            $0.mediaType == .video && $0.isEnabled
        }
        guard !videoPorts.isEmpty else {
            throw .missingVideoPort
        }

        var validated = graph
        validated.connections = graph.outputs.map { output in
            Self.connection(
                inputPorts: videoPorts,
                output: output.value,
                preserving: graph.connections
            )
        }
        return validated
    }

    private static func graphWithAutomaticConnections(
        _ graph: CaptureSessionGraph
    ) -> CaptureSessionGraph {
        guard graph.inputs.count == 1,
              !graph.outputs.isEmpty,
              graph.inputs[0].value is AVCaptureDeviceInput,
              graph.outputs.allSatisfy({
                  $0.value is AVCaptureVideoDataOutput
              })
        else {
            var incomplete = graph
            incomplete.connections = []
            return incomplete
        }
        let videoPorts = graph.inputs[0].value.ports.filter {
            $0.mediaType == .video && $0.isEnabled
        }
        guard !videoPorts.isEmpty else {
            var incomplete = graph
            incomplete.connections = []
            return incomplete
        }
        var connected = graph
        connected.connections = graph.outputs.map { output in
            Self.connection(
                inputPorts: videoPorts,
                output: output.value,
                preserving: graph.connections
            )
        }
        return connected
    }

    private static func connection(
        inputPorts: [AVCaptureInput.Port],
        output: AVCaptureOutput,
        preserving existingConnections: [AVCaptureConnection]
    ) -> AVCaptureConnection {
        let connection = AVCaptureConnection(
            inputPorts: inputPorts,
            output: output
        )
        if let existing = existingConnections.first(where: {
            $0.output === output
        }) {
            connection.videoConnectionConfiguration =
                existing.videoConnectionConfiguration
        }
        return connection
    }

    private static func synchronizeOutputConnections(
        _ graph: CaptureSessionGraph
    ) {
        for output in graph.outputs {
            output.value.replaceConnections(
                graph.connections.filter {
                    $0.output === output.value
                }
            )
        }
    }

    private static func containsIdentity(
        _ values: [CaptureInputReference],
        _ value: AVCaptureInput
    ) -> Bool {
        values.contains { $0.value === value }
    }

    private static func containsIdentity(
        _ values: [CaptureInputReference],
        _ value: CaptureInputReference
    ) -> Bool {
        containsIdentity(values, value.value)
    }

    private static func containsIdentity(
        _ values: [CaptureOutputReference],
        _ value: AVCaptureOutput
    ) -> Bool {
        values.contains { $0.value === value }
    }

    private static func containsIdentity(
        _ values: [CaptureOutputReference],
        _ value: CaptureOutputReference
    ) -> Bool {
        containsIdentity(values, value.value)
    }

    private static func releaseInputs(
        _ inputs: [AVCaptureInput],
        ownerID: ObjectIdentifier
    ) {
        for input in inputs {
            input.releaseOwnership(by: ownerID)
        }
    }

    private static func releaseOutputs(
        _ outputs: [AVCaptureOutput],
        ownerID: ObjectIdentifier
    ) {
        for output in outputs {
            output.releaseOwnership(by: ownerID)
        }
    }
}
