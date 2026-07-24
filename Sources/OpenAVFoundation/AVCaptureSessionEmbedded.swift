#if hasFeature(Embedded)
public final class AVCaptureSession {
    private let graph = AVCaptureSessionGraphStorage()
    private var lifecycle = EmbeddedCaptureSessionLifecycle()

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

    public func startRunning() throws(AVCaptureSessionError) {
        let plan = try graph.prepareToStart()
        do {
            try lifecycle.start(plan)
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

    public func stopRunning() throws(AVCaptureSessionError) {
        guard try graph.prepareToStop() else {
            return
        }
        do {
            try lifecycle.stop()
            graph.finishStop(cleanupRequired: false)
        } catch {
            graph.finishStop(cleanupRequired: true)
            throw error
        }
    }
}

private struct EmbeddedCaptureSessionResources {
    var handle: (any CaptureDeviceHandle)?
    var stream: (any CaptureStream)?
}

private struct EmbeddedCaptureSessionCleanupResult {
    var resources: EmbeddedCaptureSessionResources
    var failures: [CaptureDriverError]
}

private final class EmbeddedCaptureSessionLifecycle {
    private var resources: EmbeddedCaptureSessionResources?

    func start(
        _ plan: CaptureSessionStartPlan
    ) throws(AVCaptureSessionError) {
        precondition(resources == nil)
        var pending = EmbeddedCaptureSessionResources()

        do {
            try prepare(plan, resources: &pending)
            resources = pending
        } catch {
            let failure = error
            let cleanup = clean(pending)
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
        resources: inout EmbeddedCaptureSessionResources
    ) throws(AVCaptureSessionRuntimeFailure) {
        let handle = try openHandle(plan)
        resources.handle = handle

        let snapshot = try deviceSnapshot(handle: handle)
        try validate(
            snapshot: snapshot,
            deviceID: plan.deviceID,
            capabilityRevision: plan.capabilityRevision
        )
        let configuration = try preferredConfiguration(
            snapshot.capabilities
        )

        let configured = try configuredSnapshot(
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
        let stream = try captureStream(
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
        try start(stream: stream)
    }

    func stop() throws(AVCaptureSessionError) {
        guard let resources else {
            return
        }
        let cleanup = clean(resources)
        if cleanup.failures.isEmpty {
            self.resources = nil
            return
        }
        self.resources = cleanup.resources
        throw .stopFailures(cleanup.failures)
    }

    private func openHandle(
        _ plan: CaptureSessionStartPlan
    ) throws(AVCaptureSessionRuntimeFailure) -> any CaptureDeviceHandle {
        do {
            return try plan.opener.open(plan.deviceID)
        } catch {
            throw .driver(operation: .open, error: error)
        }
    }

    private func deviceSnapshot(
        handle: any CaptureDeviceHandle
    ) throws(AVCaptureSessionRuntimeFailure) -> CaptureDeviceSnapshot {
        do {
            return try handle.snapshot()
        } catch {
            throw .driver(operation: .capabilities, error: error)
        }
    }

    private func configuredSnapshot(
        handle: any CaptureDeviceHandle,
        configuration: CaptureDeviceConfiguration
    ) throws(AVCaptureSessionRuntimeFailure) -> CaptureDeviceSnapshot {
        do {
            return try handle.configure(configuration)
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
    ) throws(AVCaptureSessionRuntimeFailure) -> any CaptureStream {
        do {
            return try handle.stream(
                for: CaptureStreamRequest(configuration: configuration),
                sink: sink
            )
        } catch {
            throw .driver(operation: .streaming, error: error)
        }
    }

    private func start(
        stream: any CaptureStream
    ) throws(AVCaptureSessionRuntimeFailure) {
        do {
            try stream.start()
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
        _ resources: EmbeddedCaptureSessionResources
    ) -> EmbeddedCaptureSessionCleanupResult {
        var remaining = resources
        var failures: [CaptureDriverError] = []

        if let stream = remaining.stream {
            do {
                try stream.shutdown()
                remaining.stream = nil
            } catch {
                failures.append(error)
            }
        }
        if let handle = remaining.handle {
            do {
                try handle.shutdown()
                remaining.handle = nil
            } catch {
                failures.append(error)
            }
        }
        return EmbeddedCaptureSessionCleanupResult(
            resources: remaining,
            failures: failures
        )
    }
}
#endif
