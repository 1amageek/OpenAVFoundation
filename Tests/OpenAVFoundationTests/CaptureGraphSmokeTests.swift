import OpenAVFoundation
import Synchronization
import Testing

@Suite("Capture graph smoke")
struct CaptureGraphSmokeTests {
    @Test("Registry capture delivers the identical sample and stops resources")
    func captureDeliveryAndStop() async throws {
        let fixture = try CaptureGraphFixture()
        let device = try await fixture.discoveredDevice()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        let delegate = RecordingVideoDelegate()
        output.setSampleBufferDelegate(delegate)

        let session = AVCaptureSession()
        try session.beginConfiguration()
        #expect(session.canAddInput(input))
        try session.addInput(input)
        #expect(session.canAddOutput(output))
        try session.addOutput(output)
        try session.commitConfiguration()

        #expect(session.inputs.count == 1)
        #expect(session.outputs.count == 1)
        #expect(session.connections.count == 1)
        #expect(output.connections.count == 1)
        #expect(session.connections[0].inputPorts[0].input === input)
        #expect(session.connections[0].inputPorts[0].mediaType == .video)
        let inputPort = try #require(input.ports.first)
        #expect(input.ports.first === inputPort)
        #expect(session.connections[0].inputPorts.first === inputPort)
        #expect(!session.isRunning)

        try await session.startRunning()

        #expect(session.isRunning)
        let delivery = delegate.delivery()
        let deliveredSample = try #require(delivery.sampleBuffer)
        let deliveredConnection = try #require(delivery.connection)
        #expect(deliveredSample === fixture.sampleBuffer)
        #expect(deliveredConnection === session.connections[0])
        #expect(deliveredConnection.output === output)

        try await session.stopRunning()
        try await session.stopRunning()

        #expect(!session.isRunning)
        #expect(
            fixture.events.values() == [
                "open",
                "snapshot",
                "configure",
                "stream",
                "stream.start",
                "stream.shutdown",
                "handle.shutdown"
            ]
        )
    }

    @Test("Invalid commit discards the draft and preserves the committed graph")
    func invalidCommitPreservesGraph() async throws {
        let fixture = try CaptureGraphFixture()
        let device = try await fixture.discoveredDevice()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        let session = AVCaptureSession()

        try session.beginConfiguration()
        try session.addInput(input)
        try session.addOutput(output)
        try session.commitConfiguration()
        let committedConnection = try #require(session.connections.first)

        try session.beginConfiguration()
        try session.removeOutput(output)
        #expect(throws: AVCaptureSessionError.missingOutput) {
            try session.commitConfiguration()
        }

        #expect(session.inputs.first === input)
        #expect(session.outputs.first === output)
        #expect(session.connections.first === committedConnection)
        #expect(output.connections.first === committedConnection)
        #expect(throws: AVCaptureSessionError.configurationNotActive) {
            try session.commitConfiguration()
        }
    }

    @Test("A start failure rolls back opened resources")
    func startFailureRollsBackResources() async throws {
        let driverID = try CaptureDriverID("test.rollback")
        let failure = CaptureDriverError.backendFailure(
            driverID: driverID,
            deviceID: nil,
            operation: .configuration,
            code: 41
        )
        let fixture = try CaptureGraphFixture(
            driverID: driverID,
            configureFailure: failure
        )
        let session = try await fixture.configuredSession()

        await #expect(
            throws: AVCaptureSessionError.runtime(
                .driver(operation: .configuration, error: failure)
            )
        ) {
            try await session.startRunning()
        }

        #expect(!session.isRunning)
        #expect(
            fixture.events.values() == [
                "open",
                "snapshot",
                "configure",
                "handle.shutdown"
            ]
        )
        #expect(session.inputs.count == 1)
        #expect(session.outputs.count == 1)
        #expect(session.connections.count == 1)
    }

    @Test("Rollback failures preserve resources for stop retry")
    func rollbackFailureCanBeRetriedByStop() async throws {
        let driverID = try CaptureDriverID("test.rollback-retry")
        let startFailure = CaptureDriverError.backendFailure(
            driverID: driverID,
            deviceID: nil,
            operation: .start,
            code: 51
        )
        let shutdownFailure = CaptureDriverError.backendFailure(
            driverID: driverID,
            deviceID: nil,
            operation: .shutdown,
            code: 52
        )
        let fixture = try CaptureGraphFixture(
            driverID: driverID,
            startFailure: startFailure,
            streamShutdownFailures: [shutdownFailure]
        )
        let session = try await fixture.configuredSession()

        await #expect(
            throws: AVCaptureSessionError.startRollbackFailure(
                primary: .driver(
                    operation: .start,
                    error: startFailure
                ),
                cleanupFailures: [shutdownFailure]
            )
        ) {
            try await session.startRunning()
        }

        #expect(!session.isRunning)
        try await session.stopRunning()
        #expect(!session.isRunning)
        #expect(
            fixture.events.values() == [
                "open",
                "snapshot",
                "configure",
                "stream",
                "stream.start",
                "stream.shutdown",
                "handle.shutdown",
                "stream.shutdown"
            ]
        )
    }

    @Test("Session destruction releases graph ownership")
    func sessionDestructionReleasesOwnership() async throws {
        let fixture = try CaptureGraphFixture()
        let device = try await fixture.discoveredDevice()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()

        var firstSession: AVCaptureSession? = AVCaptureSession()
        try firstSession?.beginConfiguration()
        try firstSession?.addInput(input)
        try firstSession?.addOutput(output)
        try firstSession?.commitConfiguration()
        #expect(output.connections.count == 1)

        firstSession = nil

        #expect(output.connections.isEmpty)
        let secondSession = AVCaptureSession()
        try secondSession.beginConfiguration()
        #expect(secondSession.canAddInput(input))
        try secondSession.addInput(input)
        #expect(secondSession.canAddOutput(output))
        try secondSession.addOutput(output)
        try secondSession.commitConfiguration()
        #expect(secondSession.connections.count == 1)
    }

    @Test("Stable ports do not retain their input")
    func stablePortsDoNotRetainInput() async throws {
        let fixture = try CaptureGraphFixture()
        let device = try await fixture.discoveredDevice()
        weak var releasedInput: AVCaptureDeviceInput?
        var retainedPort: AVCaptureInput.Port?

        do {
            let input = try AVCaptureDeviceInput(device: device)
            releasedInput = input
            retainedPort = input.ports.first
            #expect(input.ports.first === retainedPort)
        }

        #expect(releasedInput === nil)
        #expect(retainedPort !== nil)
    }
}

private struct CaptureGraphFixture: Sendable {
    let driverID: CaptureDriverID
    let descriptor: CaptureDeviceDescriptor
    let capabilities: CaptureDeviceCapabilities
    let sampleBuffer: any CMSampleBuffer
    let provider: CaptureGraphProvider
    let events: CaptureEventLog

    init(
        driverID: CaptureDriverID? = nil,
        configureFailure: CaptureDriverError? = nil,
        startFailure: CaptureDriverError? = nil,
        streamShutdownFailures: [CaptureDriverError] = []
    ) throws {
        let resolvedDriverID: CaptureDriverID
        if let driverID {
            resolvedDriverID = driverID
        } else {
            resolvedDriverID = try CaptureDriverID("test.capture")
        }
        let deviceID = try CaptureDeviceID(
            driverID: resolvedDriverID,
            localID: "camera"
        )
        let deviceTypeID = try CaptureDeviceTypeID(
            AVCaptureDevice.DeviceType.external.rawValue
        )
        let descriptor = try CaptureDeviceDescriptor(
            deviceID: deviceID,
            deviceTypeID: deviceTypeID,
            localizedName: "Capture Camera",
            manufacturer: "Fixture",
            modelID: "capture-camera",
            position: .external,
            mediaTypes: [.video],
            capabilityRevision: 1
        )
        let format = CaptureDeviceFormatDescriptor(
            formatID: try CaptureDeviceFormatID("preferred"),
            mediaType: .video,
            mediaSubtype: CaptureMediaSubtype(rawValue: 0),
            dimensions: try CaptureDimensions(width: 2, height: 1),
            frameRateRanges: [
                try CaptureFrameRateRange(minimum: 30, maximum: 30)
            ]
        )
        let capabilities = try CaptureDeviceCapabilities(
            deviceID: deviceID,
            revision: descriptor.capabilityRevision,
            formats: [format],
            preferredFormatID: format.formatID,
            supportsConcurrentStreams: false
        )
        let snapshot = try CaptureDeviceSnapshot(
            descriptor: descriptor,
            capabilities: capabilities
        )
        let imageDimensions = try CVPixelDimensions(width: 2, height: 1)
        let imageBuffer = try CVPackedPixelBuffer(
            dimensions: imageDimensions,
            pixelFormat: .bgra32,
            bytesPerPixel: 4,
            bytesPerRow: 8
        )
        let formatDescription = CMImmutableVideoFormatDescription(
            dimensions: imageDimensions,
            pixelFormat: .bgra32
        )
        let sampleBuffer = try CMImageSampleBuffer(
            imageBuffer: imageBuffer,
            formatDescription: formatDescription,
            timing: [
                CMSampleTimingInfo(
                    duration: CMTime(value: 1, timescale: 30),
                    presentationTimeStamp: .zero,
                    decodeTimeStamp: .invalid
                )
            ]
        )
        let events = CaptureEventLog()
        let handle = CaptureGraphHandle(
            snapshot: snapshot,
            sampleBuffer: sampleBuffer,
            events: events,
            configureFailure: configureFailure,
            startFailure: startFailure,
            streamShutdownFailures: streamShutdownFailures
        )

        self.driverID = resolvedDriverID
        self.descriptor = descriptor
        self.capabilities = capabilities
        self.sampleBuffer = sampleBuffer
        self.events = events
        self.provider = CaptureGraphProvider(
            driverID: resolvedDriverID,
            descriptor: descriptor,
            handle: handle,
            events: events
        )
    }

    func discoveredDevice() async throws -> AVCaptureDevice {
        let registry = AVCaptureDeviceRegistry()
        try await registry.register(provider)
        let discovery = try await registry.discoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )
        return try #require(discovery.devices.first)
    }

    func configuredSession() async throws -> AVCaptureSession {
        let device = try await discoveredDevice()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        let session = AVCaptureSession()
        try session.beginConfiguration()
        try session.addInput(input)
        try session.addOutput(output)
        try session.commitConfiguration()
        return session
    }
}

private struct CaptureGraphProvider: CaptureDeviceProvider {
    let driverID: CaptureDriverID
    let descriptor: CaptureDeviceDescriptor
    let handle: CaptureGraphHandle
    let events: CaptureEventLog

    func authorizationStatus(
        for mediaType: CaptureMediaTypeID
    ) async -> CaptureAuthorizationStatus {
        mediaType == .video ? .authorized : .denied
    }

    func requestAccess(
        for mediaType: CaptureMediaTypeID
    ) async throws(CaptureDriverError) -> CaptureAuthorizationStatus {
        mediaType == .video ? .authorized : .denied
    }

    func devices(
        matching request: CaptureDiscoveryRequest
    ) async throws(CaptureDriverError) -> [CaptureDeviceDescriptor] {
        [descriptor]
    }

    func deviceHandle(
        for deviceID: CaptureDeviceID
    ) async throws(CaptureDriverError) -> any CaptureDeviceHandle {
        guard deviceID == descriptor.deviceID else {
            throw .deviceNotFound(deviceID)
        }
        events.append("open")
        return handle
    }
}

private actor CaptureGraphHandle: CaptureDeviceHandle {
    private let snapshotValue: CaptureDeviceSnapshot
    private let sampleBuffer: any CMSampleBuffer
    private let events: CaptureEventLog
    private let configureFailure: CaptureDriverError?
    private let startFailure: CaptureDriverError?
    private let streamShutdownFailures: [CaptureDriverError]
    private var configured: CaptureDeviceConfiguration?
    private var isShutdown = false

    init(
        snapshot: CaptureDeviceSnapshot,
        sampleBuffer: any CMSampleBuffer,
        events: CaptureEventLog,
        configureFailure: CaptureDriverError?,
        startFailure: CaptureDriverError?,
        streamShutdownFailures: [CaptureDriverError]
    ) {
        snapshotValue = snapshot
        self.sampleBuffer = sampleBuffer
        self.events = events
        self.configureFailure = configureFailure
        self.startFailure = startFailure
        self.streamShutdownFailures = streamShutdownFailures
    }

    func snapshot() throws(CaptureDriverError) -> CaptureDeviceSnapshot {
        events.append("snapshot")
        guard !isShutdown else {
            throw .deviceDisconnected(snapshotValue.descriptor.deviceID)
        }
        return snapshotValue
    }

    func configure(
        _ configuration: CaptureDeviceConfiguration
    ) throws(CaptureDriverError) -> CaptureDeviceSnapshot {
        events.append("configure")
        if let configureFailure {
            throw configureFailure
        }
        guard configuration.deviceID == snapshotValue.descriptor.deviceID else {
            throw .deviceNotFound(configuration.deviceID)
        }
        configured = configuration
        return snapshotValue
    }

    func stream(
        for request: CaptureStreamRequest,
        sink: any CaptureSampleSink
    ) throws(CaptureDriverError) -> any CaptureStream {
        events.append("stream")
        guard configured == request.configuration else {
            throw .unsupportedConfiguration(request.configuration.deviceID)
        }
        return CaptureGraphStream(
            deviceID: snapshotValue.descriptor.deviceID,
            sampleBuffer: sampleBuffer,
            sink: sink,
            events: events,
            startFailure: startFailure,
            shutdownFailures: streamShutdownFailures
        )
    }

    func shutdown() {
        events.append("handle.shutdown")
        isShutdown = true
    }
}

private actor CaptureGraphStream: CaptureStream {
    nonisolated let deviceID: CaptureDeviceID

    private let sampleBuffer: any CMSampleBuffer
    private let sink: any CaptureSampleSink
    private let events: CaptureEventLog
    private let startFailure: CaptureDriverError?
    private var shutdownFailures: [CaptureDriverError]
    private var isShutdown = false

    init(
        deviceID: CaptureDeviceID,
        sampleBuffer: any CMSampleBuffer,
        sink: any CaptureSampleSink,
        events: CaptureEventLog,
        startFailure: CaptureDriverError?,
        shutdownFailures: [CaptureDriverError]
    ) {
        self.deviceID = deviceID
        self.sampleBuffer = sampleBuffer
        self.sink = sink
        self.events = events
        self.startFailure = startFailure
        self.shutdownFailures = shutdownFailures
    }

    func start() throws(CaptureDriverError) {
        events.append("stream.start")
        if let startFailure {
            throw startFailure
        }
        guard !isShutdown else {
            throw .deviceDisconnected(deviceID)
        }
        _ = sink.offer(sampleBuffer)
    }

    func shutdown() throws(CaptureDriverError) {
        events.append("stream.shutdown")
        if !shutdownFailures.isEmpty {
            throw shutdownFailures.removeFirst()
        }
        isShutdown = true
    }
}

private final class RecordingVideoDelegate:
    AVCaptureVideoDataOutputSampleBufferDelegate,
    Sendable
{
    private struct Delivery: Sendable {
        var sampleBuffer: (any CMSampleBuffer)?
        var connection: AVCaptureConnection?
    }

    private let state = Mutex(Delivery())

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: any CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        state.withLock { state in
            state.sampleBuffer = sampleBuffer
            state.connection = connection
        }
    }

    func delivery() -> (
        sampleBuffer: (any CMSampleBuffer)?,
        connection: AVCaptureConnection?
    ) {
        state.withLock { state in
            (state.sampleBuffer, state.connection)
        }
    }
}

private final class CaptureEventLog: Sendable {
    private let events = Mutex<[String]>([])

    func append(_ event: String) {
        events.withLock { events in
            events.append(event)
        }
    }

    func values() -> [String] {
        events.withLock { events in events }
    }
}
