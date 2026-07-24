#if !hasFeature(Embedded)
public final class AVCaptureSession: Sendable {
    private let graph = AVCaptureSessionGraphStorage()
    private let lifecycle = CaptureSessionLifecycle()

    public init() {}

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
        graph.isRunning
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
        do {
            try await lifecycle.start(plan)
            graph.finishStartSuccessfully()
        } catch {
            let cleanupRequired: Bool
            switch error {
            case .startRollbackFailure:
                cleanupRequired = true
            default:
                cleanupRequired = false
            }
            graph.finishStart(cleanupRequired: cleanupRequired)
            throw error
        }
    }

    public func stopRunning() async throws(AVCaptureSessionError) {
        guard try graph.prepareToStop() else {
            return
        }
        do {
            try await lifecycle.stop()
            graph.finishStop(cleanupRequired: false)
        } catch {
            graph.finishStop(cleanupRequired: true)
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

private actor CaptureSessionLifecycle {
    private var resources: CaptureSessionResources?

    func start(
        _ plan: CaptureSessionStartPlan
    ) async throws(AVCaptureSessionError) {
        precondition(resources == nil)
        var pending = CaptureSessionResources()

        do {
            try await prepare(plan, resources: &pending)
            resources = pending
        } catch {
            let failure = error
            let cleanup = await clean(pending)
            if cleanup.failures.isEmpty {
                resources = nil
                throw .runtime(failure)
            }
            resources = cleanup.resources
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
        let configuration = try preferredConfiguration(
            snapshot.capabilities
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

        let sink = CaptureSessionSampleSink(
            delivery: plan.delivery,
            connection: plan.connection
        )
        let stream = try await captureStream(
            handle: handle,
            configuration: configuration,
            sink: sink
        )
        guard stream.deviceID == plan.deviceID else {
            throw .streamDeviceMismatch(
                expected: plan.deviceID,
                actual: stream.deviceID
            )
        }
        resources.stream = stream
        try await start(stream: stream)
    }

    func stop() async throws(AVCaptureSessionError) {
        guard let resources else {
            return
        }
        let cleanup = await clean(resources)
        if cleanup.failures.isEmpty {
            self.resources = nil
            return
        }
        self.resources = cleanup.resources
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

    private func preferredConfiguration(
        _ capabilities: CaptureDeviceCapabilities
    ) throws(AVCaptureSessionRuntimeFailure) -> CaptureDeviceConfiguration {
        do {
            return try capabilities.preferredConfiguration()
        } catch {
            throw .contract(error)
        }
    }

    private func captureStream(
        handle: any CaptureDeviceHandle,
        configuration: CaptureDeviceConfiguration,
        sink: any CaptureSampleSink
    ) async throws(AVCaptureSessionRuntimeFailure) -> any CaptureStream {
        do {
            return try await handle.stream(
                for: CaptureStreamRequest(configuration: configuration),
                sink: sink
            )
        } catch {
            throw .driver(operation: .streaming, error: error)
        }
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
