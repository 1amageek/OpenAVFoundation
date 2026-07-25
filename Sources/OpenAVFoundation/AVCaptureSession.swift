#if !hasFeature(Embedded)
import Synchronization

public final class AVCaptureSession: Sendable {
    private let graph = AVCaptureSessionGraphStorage()
    private let runtimeEvents: CaptureSessionRuntimeEventHub
    private let lifecycle: CaptureSessionLifecycle

    public init() {
        let runtimeEvents = CaptureSessionRuntimeEventHub()
        self.runtimeEvents = runtimeEvents
        lifecycle = CaptureSessionLifecycle(runtimeEvents: runtimeEvents)
    }

    public var inputs: [AVCaptureInput] {
        graph.inputs
    }

    public var outputs: [AVCaptureOutput] {
        graph.outputs
    }

    public var connections: [AVCaptureConnection] {
        graph.connections
    }

    public var isRunning: Bool {
        graph.isRunning && runtimeEvents.isActive
    }

    public var runtimeState: AVCaptureSessionRuntimeState {
        runtimeEvents.runtimeState
    }

    public var systemPressure: CaptureSystemPressure? {
        runtimeEvents.pressure
    }

    public var lastSourceDrop: CaptureStreamDropEvent? {
        runtimeEvents.lastSourceDrop
    }

    public func setRuntimeEventSink(
        _ sink: (any AVCaptureSessionRuntimeEventSink)?
    ) {
        runtimeEvents.setSink(sink)
    }

    public func beginConfiguration() throws(AVCaptureSessionError) {
        try graph.beginConfiguration()
    }

    public func commitConfiguration() throws(AVCaptureSessionError) {
        try graph.commitConfiguration()
    }

    public func canAddInput(_ input: AVCaptureInput) -> Bool {
        graph.canAddInput(input)
    }

    public func addInput(
        _ input: AVCaptureInput
    ) throws(AVCaptureSessionError) {
        try graph.addInput(input)
    }

    public func removeInput(
        _ input: AVCaptureInput
    ) throws(AVCaptureSessionError) {
        try graph.removeInput(input)
    }

    public func canAddOutput(_ output: AVCaptureOutput) -> Bool {
        graph.canAddOutput(output)
    }

    public func addOutput(
        _ output: AVCaptureOutput
    ) throws(AVCaptureSessionError) {
        try graph.addOutput(output)
    }

    public func removeOutput(
        _ output: AVCaptureOutput
    ) throws(AVCaptureSessionError) {
        try graph.removeOutput(output)
    }

    public func startRunning() async throws(AVCaptureSessionError) {
        let plan = try graph.prepareToStart()
        runtimeEvents.beginStart(routes: plan.routes)
        do {
            try await lifecycle.start(plan)
            graph.finishStartSuccessfully()
            runtimeEvents.finishStartSuccessfully()
        } catch {
            let cleanupRequired: Bool
            let cleanupFailures: [CaptureDriverError]?
            switch error {
            case let .startRollbackFailure(_, failures):
                cleanupRequired = true
                cleanupFailures = failures
            default:
                cleanupRequired = false
                cleanupFailures = nil
            }
            graph.finishStart(cleanupRequired: cleanupRequired)
            runtimeEvents.finishStart(cleanupFailures: cleanupFailures)
            throw error
        }
    }

    public func stopRunning() async throws(AVCaptureSessionError) {
        guard try graph.prepareToStop() else {
            return
        }
        runtimeEvents.beginStop()
        do {
            try await lifecycle.stop()
            graph.finishStop(cleanupRequired: false)
            runtimeEvents.finishStop(cleanupFailures: nil)
        } catch {
            graph.finishStop(cleanupRequired: true)
            let cleanupFailures: [CaptureDriverError]
            switch error {
            case let .stopFailures(failures):
                cleanupFailures = failures
            default:
                cleanupFailures = []
            }
            runtimeEvents.finishStop(cleanupFailures: cleanupFailures)
            throw error
        }
    }
}

private struct CaptureSessionResources: Sendable {
    var handle: (any CaptureDeviceHandle)?
    var stream: (any CaptureStream)?
}

private struct CaptureSessionCleanupResult: Sendable {
    var resources: CaptureSessionResources
    var failures: [CaptureDriverError]
}

private final class CaptureSessionLifecycle: Sendable {
    private enum Phase: Sendable {
        case idle
        case starting
        case running
        case stopping
    }

    private struct State: Sendable {
        var phase = Phase.idle
        var resources: CaptureSessionResources?
    }

    private let state = Mutex(State())
    private let runtimeEvents: CaptureSessionRuntimeEventHub

    init(runtimeEvents: CaptureSessionRuntimeEventHub) {
        self.runtimeEvents = runtimeEvents
    }

    func start(
        _ plan: CaptureSessionStartPlan
    ) async throws(AVCaptureSessionError) {
        let reserved = state.withLock { state in
            guard state.phase == .idle, state.resources == nil else {
                return false
            }
            state.phase = .starting
            return true
        }
        guard reserved else {
            throw .sessionBusy
        }
        var pending = CaptureSessionResources()

        do {
            try await prepare(plan, resources: &pending)
            state.withLock { state in
                state.resources = pending
                state.phase = .running
            }
        } catch {
            let failure = error
            let cleanup = await clean(pending)
            if cleanup.failures.isEmpty {
                state.withLock { state in
                    state.resources = nil
                    state.phase = .idle
                }
                throw .runtime(failure)
            }
            state.withLock { state in
                state.resources = cleanup.resources
                state.phase = .running
            }
            throw .startRollbackFailure(
                primary: failure,
                cleanupFailures: cleanup.failures
            )
        }
    }

    private func prepare(
        _ plan: CaptureSessionStartPlan,
        resources: inout CaptureSessionResources
    ) async throws(AVCaptureSessionRuntimeFailure) {
        let handle = try await openHandle(plan)
        resources.handle = handle

        let snapshot = try await deviceSnapshot(
            handle: handle,
            operation: .capabilities
        )
        try validate(
            snapshot: snapshot,
            deviceID: plan.deviceID,
            capabilityRevision: plan.capabilityRevision
        )
        let configuration = try plan.device.configuration(
            for: snapshot.capabilities
        )

        let configured = try await configuredSnapshot(
            handle: handle,
            configuration: configuration
        )
        try validate(
            snapshot: configured,
            deviceID: plan.deviceID,
            capabilityRevision: plan.capabilityRevision
        )

        let request = try streamRequest(
            configuration: configuration,
            videoConnectionConfiguration:
                plan.videoConnectionConfiguration,
            capabilities: configured.capabilities
        )
        let sink = CaptureSessionSampleSink(routes: plan.routes)
        let stream = try await captureStream(
            handle: handle,
            request: request,
            sink: sink
        )
        guard stream.deviceID == plan.deviceID else {
            throw .streamDeviceMismatch(
                expected: plan.deviceID,
                actual: stream.deviceID
            )
        }
        resources.stream = stream
        try installRuntimeEventSink(
            on: stream,
            request: request,
            capabilities: configured.capabilities
        )
        try await start(stream: stream)
    }

    func stop() async throws(AVCaptureSessionError) {
        let resources = state.withLock {
            state -> CaptureSessionResources? in
            guard state.phase == .running,
                  let resources = state.resources else {
                return nil
            }
            state.phase = .stopping
            return resources
        }
        guard let resources else {
            throw .sessionBusy
        }
        let cleanup = await clean(resources)
        if cleanup.failures.isEmpty {
            state.withLock { state in
                state.resources = nil
                state.phase = .idle
            }
            return
        }
        state.withLock { state in
            state.resources = cleanup.resources
            state.phase = .running
        }
        throw .stopFailures(cleanup.failures)
    }

    private func openHandle(
        _ plan: CaptureSessionStartPlan
    ) async throws(AVCaptureSessionRuntimeFailure) -> any CaptureDeviceHandle {
        do {
            return try await plan.opener.open(plan.deviceID)
        } catch {
            throw .driver(operation: .open, error: error)
        }
    }

    private func deviceSnapshot(
        handle: any CaptureDeviceHandle,
        operation: CaptureDriverOperation
    ) async throws(AVCaptureSessionRuntimeFailure) -> CaptureDeviceSnapshot {
        do {
            return try await handle.snapshot()
        } catch {
            throw .driver(operation: operation, error: error)
        }
    }

    private func configuredSnapshot(
        handle: any CaptureDeviceHandle,
        configuration: CaptureDeviceConfiguration
    ) async throws(AVCaptureSessionRuntimeFailure) -> CaptureDeviceSnapshot {
        do {
            return try await handle.configure(configuration)
        } catch {
            throw .driver(operation: .configuration, error: error)
        }
    }

    private func captureStream(
        handle: any CaptureDeviceHandle,
        request: CaptureStreamRequest,
        sink: any CaptureSampleSink
    ) async throws(AVCaptureSessionRuntimeFailure) -> any CaptureStream {
        do {
            return try await handle.stream(
                for: request,
                sink: sink
            )
        } catch {
            throw .driver(operation: .streaming, error: error)
        }
    }

    private func streamRequest(
        configuration: CaptureDeviceConfiguration,
        videoConnectionConfiguration: CaptureVideoConnectionConfiguration,
        capabilities: CaptureDeviceCapabilities
    ) throws(AVCaptureSessionRuntimeFailure) -> CaptureStreamRequest {
        let request = CaptureStreamRequest(
            configuration: configuration,
            videoConnectionConfiguration: videoConnectionConfiguration
        )
        if capabilities.streams.isEmpty,
           videoConnectionConfiguration == .unchanged {
            return request
        }
        do {
            return try capabilities.validatedStreamRequest(request)
        } catch {
            throw .driver(operation: .streaming, error: error)
        }
    }

    private func installRuntimeEventSink(
        on stream: any CaptureStream,
        request: CaptureStreamRequest,
        capabilities: CaptureDeviceCapabilities
    ) throws(AVCaptureSessionRuntimeFailure) {
        let expected = Self.eventCapabilities(
            for: request,
            in: capabilities
        )
        guard stream.eventCapabilities == expected else {
            throw .streamEventCapabilitiesMismatch(
                expected: expected,
                actual: stream.eventCapabilities
            )
        }
        guard !expected.isEmpty else {
            return
        }
        runtimeEvents.setEventCapabilities(expected)
        do {
            try stream.setEventSink(runtimeEvents)
        } catch {
            throw .driver(operation: .streaming, error: error)
        }
    }

    private static func eventCapabilities(
        for request: CaptureStreamRequest,
        in capabilities: CaptureDeviceCapabilities
    ) -> CaptureStreamEventCapabilities {
        if let streamID = request.streamID {
            return capabilities.streams.first {
                $0.streamID == streamID
            }?.eventCapabilities ?? []
        }
        return capabilities.streams.first {
            $0.formatIDs.contains(request.configuration.formatID)
        }?.eventCapabilities ?? []
    }

    private func start(
        stream: any CaptureStream
    ) async throws(AVCaptureSessionRuntimeFailure) {
        do {
            try await stream.start()
        } catch {
            throw .driver(operation: .start, error: error)
        }
    }

    private func validate(
        snapshot: CaptureDeviceSnapshot,
        deviceID: CaptureDeviceID,
        capabilityRevision: UInt64
    ) throws(AVCaptureSessionRuntimeFailure) {
        guard snapshot.descriptor.deviceID == deviceID else {
            throw .snapshotDeviceMismatch(
                expected: deviceID,
                actual: snapshot.descriptor.deviceID
            )
        }
        guard snapshot.capabilities.revision == capabilityRevision else {
            throw .snapshotRevisionMismatch(
                deviceID: deviceID,
                expected: capabilityRevision,
                actual: snapshot.capabilities.revision
            )
        }
    }

    private func clean(
        _ resources: CaptureSessionResources
    ) async -> CaptureSessionCleanupResult {
        var remaining = resources
        var failures: [CaptureDriverError] = []

        if let stream = remaining.stream {
            do {
                try await stream.shutdown()
                remaining.stream = nil
            } catch {
                failures.append(error)
            }
        }
        if let handle = remaining.handle {
            do {
                try await handle.shutdown()
                remaining.handle = nil
            } catch {
                failures.append(error)
            }
        }
        return CaptureSessionCleanupResult(
            resources: remaining,
            failures: failures
        )
    }
}
#endif
