#if !hasFeature(Embedded)
import Synchronization
#endif

final class CaptureSessionOwner: Sendable {}

enum CaptureSessionPhase {
    case idle
    case starting
    case running
    case stopping
    case cleanupRequired
}

struct CaptureSessionGraph {
    var inputs: [CaptureInputReference] = []
    var outputs: [CaptureOutputReference] = []
    var connections: [AVCaptureConnection] = []
}

struct CaptureInputReference: Sendable {
    nonisolated(unsafe) let value: AVCaptureInput
}

struct CaptureOutputReference: Sendable {
    nonisolated(unsafe) let value: AVCaptureOutput
}

struct CaptureSessionStartPlan {
    let deviceID: CaptureDeviceID
    let capabilityRevision: UInt64
    let opener: CaptureDeviceHandleOpener
    let delivery: VideoOutputDelivery
    let connection: AVCaptureConnection
}

#if !hasFeature(Embedded)
extension CaptureSessionStartPlan: Sendable {}
#endif

final class AVCaptureSessionGraphStorage {
    private struct State {
        var committed = CaptureSessionGraph()
        var draft: CaptureSessionGraph?
        var phase = CaptureSessionPhase.idle
    }

    private let owner = CaptureSessionOwner()

#if hasFeature(Embedded)
    private var state = State()
#else
    private let state = Mutex(State())
#endif

    private var ownerID: ObjectIdentifier {
        ObjectIdentifier(owner)
    }

    deinit {
        let graph: CaptureSessionGraph
#if hasFeature(Embedded)
        graph = state.committed
#else
        graph = state.withLock { state in state.committed }
#endif
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
#if hasFeature(Embedded)
        state.committed.inputs.map { reference in
            reference.value
        }
#else
        state.withLock { state in
            state.committed.inputs.map { reference in
                reference.value
            }
        }
#endif
    }

    var outputs: [AVCaptureOutput] {
#if hasFeature(Embedded)
        state.committed.outputs.map { reference in
            reference.value
        }
#else
        state.withLock { state in
            state.committed.outputs.map { reference in
                reference.value
            }
        }
#endif
    }

    var connections: [AVCaptureConnection] {
#if hasFeature(Embedded)
        state.committed.connections
#else
        state.withLock { state in state.committed.connections }
#endif
    }

    var isRunning: Bool {
#if hasFeature(Embedded)
        state.phase == .running
#else
        state.withLock { state in state.phase == .running }
#endif
    }

    func beginConfiguration() throws(AVCaptureSessionError) {
#if hasFeature(Embedded)
        try Self.beginConfiguration(state: &state)
#else
        try state.withLock { state throws(AVCaptureSessionError) in
            try Self.beginConfiguration(state: &state)
        }
#endif
    }

    func commitConfiguration() throws(AVCaptureSessionError) {
#if hasFeature(Embedded)
        try Self.commitConfiguration(
            state: &state,
            ownerID: ownerID
        )
#else
        try state.withLock { state throws(AVCaptureSessionError) in
            try Self.commitConfiguration(
                state: &state,
                ownerID: ownerID
            )
        }
#endif
    }

    func canAddInput(_ input: AVCaptureInput) -> Bool {
#if hasFeature(Embedded)
        Self.canAddInput(input, state: state, ownerID: ownerID)
#else
        nonisolated(unsafe) let input = input
        return state.withLock { state in
            Self.canAddInput(input, state: state, ownerID: ownerID)
        }
#endif
    }

    func addInput(
        _ input: AVCaptureInput
    ) throws(AVCaptureSessionError) {
#if hasFeature(Embedded)
        try Self.addInput(input, state: &state, ownerID: ownerID)
#else
        nonisolated(unsafe) let input = input
        try state.withLock { state throws(AVCaptureSessionError) in
            try Self.addInput(input, state: &state, ownerID: ownerID)
        }
#endif
    }

    func removeInput(
        _ input: AVCaptureInput
    ) throws(AVCaptureSessionError) {
#if hasFeature(Embedded)
        try Self.removeInput(input, state: &state, ownerID: ownerID)
#else
        nonisolated(unsafe) let input = input
        try state.withLock { state throws(AVCaptureSessionError) in
            try Self.removeInput(input, state: &state, ownerID: ownerID)
        }
#endif
    }

    func canAddOutput(_ output: AVCaptureOutput) -> Bool {
#if hasFeature(Embedded)
        Self.canAddOutput(output, state: state, ownerID: ownerID)
#else
        nonisolated(unsafe) let output = output
        return state.withLock { state in
            Self.canAddOutput(output, state: state, ownerID: ownerID)
        }
#endif
    }

    func addOutput(
        _ output: AVCaptureOutput
    ) throws(AVCaptureSessionError) {
#if hasFeature(Embedded)
        try Self.addOutput(output, state: &state, ownerID: ownerID)
#else
        nonisolated(unsafe) let output = output
        try state.withLock { state throws(AVCaptureSessionError) in
            try Self.addOutput(output, state: &state, ownerID: ownerID)
        }
#endif
    }

    func removeOutput(
        _ output: AVCaptureOutput
    ) throws(AVCaptureSessionError) {
#if hasFeature(Embedded)
        try Self.removeOutput(output, state: &state, ownerID: ownerID)
#else
        nonisolated(unsafe) let output = output
        try state.withLock { state throws(AVCaptureSessionError) in
            try Self.removeOutput(output, state: &state, ownerID: ownerID)
        }
#endif
    }

    func prepareToStart()
        throws(AVCaptureSessionError) -> CaptureSessionStartPlan
    {
#if hasFeature(Embedded)
        try Self.prepareToStart(state: &state)
#else
        try state.withLock { state throws(AVCaptureSessionError) in
            try Self.prepareToStart(state: &state)
        }
#endif
    }

    func finishStart(cleanupRequired: Bool) {
#if hasFeature(Embedded)
        state.phase = cleanupRequired ? .cleanupRequired : .idle
#else
        state.withLock { state in
            state.phase = cleanupRequired ? .cleanupRequired : .idle
        }
#endif
    }

    func finishStartSuccessfully() {
#if hasFeature(Embedded)
        state.phase = .running
#else
        state.withLock { state in state.phase = .running }
#endif
    }

    func prepareToStop() throws(AVCaptureSessionError) -> Bool {
#if hasFeature(Embedded)
        try Self.prepareToStop(state: &state)
#else
        try state.withLock { state throws(AVCaptureSessionError) in
            try Self.prepareToStop(state: &state)
        }
#endif
    }

    func finishStop(cleanupRequired: Bool) {
#if hasFeature(Embedded)
        state.phase = cleanupRequired ? .cleanupRequired : .idle
#else
        state.withLock { state in
            state.phase = cleanupRequired ? .cleanupRequired : .idle
        }
#endif
    }

    private static func beginConfiguration(
        state: inout State
    ) throws(AVCaptureSessionError) {
        guard state.phase == .idle else {
            throw .configurationWhileRunningUnsupported
        }
        guard state.draft == nil else {
            throw .configurationAlreadyActive
        }
        state.draft = state.committed
    }

    private static func commitConfiguration(
        state: inout State,
        ownerID: ObjectIdentifier
    ) throws(AVCaptureSessionError) {
        guard let draft = state.draft else {
            throw .configurationNotActive
        }

        // A failed commit always discards its draft before reporting failure.
        state.draft = nil
        let validated = try validatedCompleteGraph(draft)

        var newlyClaimedInputs: [AVCaptureInput] = []
        for input in validated.inputs
        where !containsIdentity(state.committed.inputs, input) {
            guard input.value.claimOwnership(by: ownerID) else {
                releaseInputs(newlyClaimedInputs, ownerID: ownerID)
                throw .inputOwnedByAnotherSession
            }
            newlyClaimedInputs.append(input.value)
        }

        var newlyClaimedOutputs: [AVCaptureOutput] = []
        for output in validated.outputs
        where !containsIdentity(state.committed.outputs, output) {
            guard output.value.claimOwnership(by: ownerID) else {
                releaseOutputs(newlyClaimedOutputs, ownerID: ownerID)
                releaseInputs(newlyClaimedInputs, ownerID: ownerID)
                throw .outputOwnedByAnotherSession
            }
            newlyClaimedOutputs.append(output.value)
        }

        let previous = state.committed
        state.committed = validated
        synchronizeOutputConnections(validated)

        for input in previous.inputs
        where !containsIdentity(validated.inputs, input) {
            input.value.releaseOwnership(by: ownerID)
        }
        for output in previous.outputs
        where !containsIdentity(validated.outputs, output) {
            output.value.replaceConnections([])
            output.value.releaseOwnership(by: ownerID)
        }
    }

    private static func canAddInput(
        _ input: AVCaptureInput,
        state: State,
        ownerID: ObjectIdentifier
    ) -> Bool {
        guard state.phase == .idle,
              input is AVCaptureDeviceInput,
              input.ports.contains(where: {
                  $0.mediaType == .video && $0.isEnabled
              })
        else {
            return false
        }
        let graph = state.draft ?? state.committed
        return graph.inputs.isEmpty
            && !containsIdentity(graph.inputs, input)
            && input.canBeOwned(by: ownerID)
    }

    private static func addInput(
        _ input: AVCaptureInput,
        state: inout State,
        ownerID: ObjectIdentifier
    ) throws(AVCaptureSessionError) {
        guard state.phase == .idle else {
            throw .configurationWhileRunningUnsupported
        }
        guard input is AVCaptureDeviceInput,
              input.ports.contains(where: {
                  $0.mediaType == .video && $0.isEnabled
              })
        else {
            throw .unsupportedInput
        }

        if var draft = state.draft {
            guard !containsIdentity(draft.inputs, input) else {
                throw .duplicateInput
            }
            guard draft.inputs.isEmpty else {
                throw .inputLimitReached
            }
            guard input.canBeOwned(by: ownerID) else {
                throw .inputOwnedByAnotherSession
            }
            draft.inputs.append(CaptureInputReference(value: input))
            state.draft = draft
            return
        }

        guard !containsIdentity(state.committed.inputs, input) else {
            throw .duplicateInput
        }
        guard state.committed.inputs.isEmpty else {
            throw .inputLimitReached
        }
        guard input.claimOwnership(by: ownerID) else {
            throw .inputOwnedByAnotherSession
        }
        state.committed.inputs.append(
            CaptureInputReference(value: input)
        )
        state.committed = graphWithAutomaticConnections(state.committed)
        synchronizeOutputConnections(state.committed)
    }

    private static func removeInput(
        _ input: AVCaptureInput,
        state: inout State,
        ownerID: ObjectIdentifier
    ) throws(AVCaptureSessionError) {
        guard state.phase == .idle else {
            throw .configurationWhileRunningUnsupported
        }
        if var draft = state.draft {
            draft.inputs.removeAll { $0.value === input }
            draft.connections = []
            state.draft = draft
            return
        }
        let existed = containsIdentity(state.committed.inputs, input)
        state.committed.inputs.removeAll { $0.value === input }
        state.committed = graphWithAutomaticConnections(state.committed)
        synchronizeOutputConnections(state.committed)
        if existed {
            input.releaseOwnership(by: ownerID)
        }
    }

    private static func canAddOutput(
        _ output: AVCaptureOutput,
        state: State,
        ownerID: ObjectIdentifier
    ) -> Bool {
        guard state.phase == .idle,
              output is AVCaptureVideoDataOutput
        else {
            return false
        }
        let graph = state.draft ?? state.committed
        return graph.outputs.isEmpty
            && !containsIdentity(graph.outputs, output)
            && output.canBeOwned(by: ownerID)
    }

    private static func addOutput(
        _ output: AVCaptureOutput,
        state: inout State,
        ownerID: ObjectIdentifier
    ) throws(AVCaptureSessionError) {
        guard state.phase == .idle else {
            throw .configurationWhileRunningUnsupported
        }
        guard output is AVCaptureVideoDataOutput else {
            throw .unsupportedOutput
        }

        if var draft = state.draft {
            guard !containsIdentity(draft.outputs, output) else {
                throw .duplicateOutput
            }
            guard draft.outputs.isEmpty else {
                throw .outputLimitReached
            }
            guard output.canBeOwned(by: ownerID) else {
                throw .outputOwnedByAnotherSession
            }
            draft.outputs.append(CaptureOutputReference(value: output))
            state.draft = draft
            return
        }

        guard !containsIdentity(state.committed.outputs, output) else {
            throw .duplicateOutput
        }
        guard state.committed.outputs.isEmpty else {
            throw .outputLimitReached
        }
        guard output.claimOwnership(by: ownerID) else {
            throw .outputOwnedByAnotherSession
        }
        state.committed.outputs.append(
            CaptureOutputReference(value: output)
        )
        state.committed = graphWithAutomaticConnections(state.committed)
        synchronizeOutputConnections(state.committed)
    }

    private static func removeOutput(
        _ output: AVCaptureOutput,
        state: inout State,
        ownerID: ObjectIdentifier
    ) throws(AVCaptureSessionError) {
        guard state.phase == .idle else {
            throw .configurationWhileRunningUnsupported
        }
        if var draft = state.draft {
            draft.outputs.removeAll { $0.value === output }
            draft.connections = []
            state.draft = draft
            return
        }
        let existed = containsIdentity(state.committed.outputs, output)
        state.committed.outputs.removeAll { $0.value === output }
        state.committed = graphWithAutomaticConnections(state.committed)
        synchronizeOutputConnections(state.committed)
        if existed {
            output.replaceConnections([])
            output.releaseOwnership(by: ownerID)
        }
    }

    private static func prepareToStart(
        state: inout State
    ) throws(AVCaptureSessionError) -> CaptureSessionStartPlan {
        guard state.draft == nil else {
            throw .configurationInProgress
        }
        guard state.phase == .idle else {
            throw .sessionBusy
        }
        let graph = try validatedCompleteGraph(state.committed)
        state.committed = graph
        synchronizeOutputConnections(graph)
        state.phase = .starting

        guard let input =
                graph.inputs[0].value as? AVCaptureDeviceInput,
              let output =
                graph.outputs[0].value as? AVCaptureVideoDataOutput
        else {
            // validatedCompleteGraph guarantees these concrete types.
            preconditionFailure("Validated capture graph lost its concrete types.")
        }
        return CaptureSessionStartPlan(
            deviceID: input.device.captureDeviceID,
            capabilityRevision: input.device.descriptor.capabilityRevision,
            opener: input.device.handleOpener,
            delivery: output.deliveryEndpoint,
            connection: graph.connections[0]
        )
    }

    private static func prepareToStop(
        state: inout State
    ) throws(AVCaptureSessionError) -> Bool {
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

    private static func validatedCompleteGraph(
        _ graph: CaptureSessionGraph
    ) throws(AVCaptureSessionError) -> CaptureSessionGraph {
        // FIXME(INCOMPLETE_IMPLEMENTATION): Session start currently routes one video
        // device input to one video data output through this validator. It must
        // not accept additional routes until source sharing, bounded fan-out,
        // per-output backpressure, and lease release are implemented.
        guard !graph.inputs.isEmpty else {
            throw .missingInput
        }
        guard graph.inputs.count == 1 else {
            throw .inputLimitReached
        }
        guard !graph.outputs.isEmpty else {
            throw .missingOutput
        }
        guard graph.outputs.count == 1 else {
            throw .outputLimitReached
        }
        guard graph.inputs[0].value is AVCaptureDeviceInput else {
            throw .unsupportedInput
        }
        guard graph.outputs[0].value is AVCaptureVideoDataOutput else {
            throw .unsupportedOutput
        }
        let videoPorts = graph.inputs[0].value.ports.filter {
            $0.mediaType == .video && $0.isEnabled
        }
        guard !videoPorts.isEmpty else {
            throw .missingVideoPort
        }

        var validated = graph
        validated.connections = [
            AVCaptureConnection(
                inputPorts: videoPorts,
                output: graph.outputs[0].value
            )
        ]
        return validated
    }

    private static func graphWithAutomaticConnections(
        _ graph: CaptureSessionGraph
    ) -> CaptureSessionGraph {
        guard graph.inputs.count == 1,
              graph.outputs.count == 1,
              graph.inputs[0].value is AVCaptureDeviceInput,
              graph.outputs[0].value is AVCaptureVideoDataOutput
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
        connected.connections = [
            AVCaptureConnection(
                inputPorts: videoPorts,
                output: graph.outputs[0].value
            )
        ]
        return connected
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

#if !hasFeature(Embedded)
extension AVCaptureSessionGraphStorage: Sendable {}
#endif
