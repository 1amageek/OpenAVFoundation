import OpenAVFoundation
import Testing

@Suite("Device discovery smoke")
struct DeviceDiscoverySmokeTests {
    @Test("Registered providers produce stable driver-namespaced devices")
    func registeredProvidersProduceStableDevices() async throws {
        let fixture = try TestFixture()
        let registry = AVCaptureDeviceRegistry()
        try await registry.register(
            TestCaptureProvider(
                driverID: fixture.firstDriverID,
                descriptors: [fixture.firstDescriptor]
            )
        )
        try await registry.register(
            TestCaptureProvider(
                driverID: fixture.secondDriverID,
                descriptors: [fixture.secondDescriptor]
            )
        )

        let firstSession = try await registry.discoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )
        let secondSession = try await registry.discoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )

        #expect(firstSession.devices.count == 2)
        let firstDevice = try #require(firstSession.devices.first)
        let secondDevice = try #require(firstSession.devices.last)
        let repeatedFirstDevice = try #require(secondSession.devices.first)
        let repeatedSecondDevice = try #require(secondSession.devices.last)
        #expect(firstDevice.uniqueID != secondDevice.uniqueID)
        #expect(firstDevice === repeatedFirstDevice)
        #expect(secondDevice === repeatedSecondDevice)
        #expect(firstSession.devices.allSatisfy { $0.hasMediaType(.video) })
    }

    @Test("Discovery filters provider results at the framework boundary")
    func discoveryFiltersProviderResults() async throws {
        let fixture = try TestFixture()
        let registry = AVCaptureDeviceRegistry()
        try await registry.register(
            TestCaptureProvider(
                driverID: fixture.firstDriverID,
                descriptors: [fixture.firstDescriptor, fixture.audioDescriptor]
            )
        )

        let session = try await registry.discoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .front
        )

        #expect(session.devices.count == 1)
        let device = try #require(session.devices.first)
        #expect(device.localizedName == "First Camera")
        #expect(device.position == .front)
    }

    @Test("Authorization maps provider status and request results")
    func authorizationMapping() async throws {
        let fixture = try TestFixture()
        let registry = AVCaptureDeviceRegistry()
        let provider = TestCaptureProvider(
            driverID: fixture.firstDriverID,
            descriptors: [fixture.firstDescriptor],
            authorizationStatus: .notDetermined,
            requestedAuthorizationStatus: .authorized
        )
        try await registry.register(provider)

        let initial = try await registry.authorizationStatus(
            for: .video,
            providerID: fixture.firstDriverID
        )
        let granted = try await registry.requestAccess(
            for: .video,
            providerID: fixture.firstDriverID
        )
        let resulting = try await registry.authorizationStatus(
            for: .video,
            providerID: fixture.firstDriverID
        )

        #expect(initial == .notDetermined)
        #expect(granted)
        #expect(resulting == .authorized)
    }

    @Test("A denied authorization request maps to false")
    func deniedAuthorizationMapsToFalse() async throws {
        let fixture = try TestFixture()
        let registry = AVCaptureDeviceRegistry()
        let provider = TestCaptureProvider(
            driverID: fixture.firstDriverID,
            descriptors: [fixture.firstDescriptor],
            authorizationStatus: .notDetermined,
            requestedAuthorizationStatus: .denied
        )
        try await registry.register(provider)

        let granted = try await registry.requestAccess(
            for: .video,
            providerID: fixture.firstDriverID
        )
        let resulting = try await registry.authorizationStatus(
            for: .video,
            providerID: fixture.firstDriverID
        )

        #expect(!granted)
        #expect(resulting == .denied)
    }

    @Test("Duplicate provider registration is rejected")
    func duplicateProviderRegistration() async throws {
        let fixture = try TestFixture()
        let registry = AVCaptureDeviceRegistry()
        let provider = TestCaptureProvider(
            driverID: fixture.firstDriverID,
            descriptors: [fixture.firstDescriptor]
        )
        try await registry.register(provider)

        await #expect(
            throws: AVCaptureDeviceError.duplicateProvider(fixture.firstDriverID)
        ) {
            try await registry.register(provider)
        }
    }

    @Test("Unknown provider authorization is rejected")
    func unknownProviderAuthorization() async throws {
        let fixture = try TestFixture()
        let registry = AVCaptureDeviceRegistry()

        await #expect(
            throws: AVCaptureDeviceError.unknownProvider(fixture.firstDriverID)
        ) {
            try await registry.authorizationStatus(
                for: .video,
                providerID: fixture.firstDriverID
            )
        }
    }

    @Test("Unsupported authorization media type is rejected")
    func unsupportedAuthorizationMediaType() async throws {
        let fixture = try TestFixture()
        let registry = AVCaptureDeviceRegistry()
        try await registry.register(
            TestCaptureProvider(
                driverID: fixture.firstDriverID,
                descriptors: [fixture.firstDescriptor]
            )
        )

        await #expect(
            throws: AVCaptureDeviceError.unsupportedAuthorizationMediaType(
                .metadata
            )
        ) {
            try await registry.authorizationStatus(
                for: .metadata,
                providerID: fixture.firstDriverID
            )
        }
    }

    @Test("Provider discovery failure remains typed")
    func providerFailureRemainsTyped() async throws {
        let fixture = try TestFixture()
        let registry = AVCaptureDeviceRegistry()
        let providerError = CaptureDriverError.providerUnavailable(
            driverID: fixture.firstDriverID
        )
        try await registry.register(
            TestCaptureProvider(
                driverID: fixture.firstDriverID,
                descriptors: [],
                discoveryError: providerError
            )
        )

        await #expect(
            throws: AVCaptureDeviceError.providerFailure(
                driverID: fixture.firstDriverID,
                error: providerError
            )
        ) {
            try await registry.discoverySession(
                deviceTypes: [.external],
                mediaType: .video,
                position: .unspecified
            )
        }
    }

    @Test("Duplicate device descriptors are rejected")
    func duplicateDeviceDescriptorsAreRejected() async throws {
        let fixture = try TestFixture()
        let registry = AVCaptureDeviceRegistry()
        try await registry.register(
            TestCaptureProvider(
                driverID: fixture.firstDriverID,
                descriptors: [fixture.firstDescriptor, fixture.firstDescriptor]
            )
        )

        await #expect(
            throws: AVCaptureDeviceError.duplicateDevice(
                fixture.firstDescriptor.deviceID
            )
        ) {
            try await registry.discoverySession(
                deviceTypes: [.external],
                mediaType: .video,
                position: .unspecified
            )
        }
    }

    @Test("A provider cannot publish another driver's device")
    func foreignDeviceDescriptorIsRejected() async throws {
        let fixture = try TestFixture()
        let registry = AVCaptureDeviceRegistry()
        try await registry.register(
            TestCaptureProvider(
                driverID: fixture.firstDriverID,
                descriptors: [fixture.secondDescriptor]
            )
        )

        await #expect(
            throws: AVCaptureDeviceError.providerReturnedForeignDevice(
                providerID: fixture.firstDriverID,
                deviceID: fixture.secondDescriptor.deviceID
            )
        ) {
            try await registry.discoverySession(
                deviceTypes: [.external],
                mediaType: .video,
                position: .unspecified
            )
        }
    }
}

private struct TestFixture {
    let firstDriverID: CaptureDriverID
    let secondDriverID: CaptureDriverID
    let firstDescriptor: CaptureDeviceDescriptor
    let secondDescriptor: CaptureDeviceDescriptor
    let audioDescriptor: CaptureDeviceDescriptor

    init() throws {
        firstDriverID = try CaptureDriverID("test.first")
        secondDriverID = try CaptureDriverID("test.second")
        let deviceType = try CaptureDeviceTypeID(
            AVCaptureDevice.DeviceType.external.rawValue
        )
        firstDescriptor = try CaptureDeviceDescriptor(
            deviceID: CaptureDeviceID(
                driverID: firstDriverID,
                localID: "shared-local-id"
            ),
            deviceTypeID: deviceType,
            localizedName: "First Camera",
            manufacturer: "Fixture",
            modelID: "camera-1",
            position: .front,
            mediaTypes: [.video],
            capabilityRevision: 1
        )
        secondDescriptor = try CaptureDeviceDescriptor(
            deviceID: CaptureDeviceID(
                driverID: secondDriverID,
                localID: "shared-local-id"
            ),
            deviceTypeID: deviceType,
            localizedName: "Second Camera",
            manufacturer: "Fixture",
            modelID: "camera-2",
            position: .back,
            mediaTypes: [.video],
            capabilityRevision: 1
        )
        audioDescriptor = try CaptureDeviceDescriptor(
            deviceID: CaptureDeviceID(
                driverID: firstDriverID,
                localID: "microphone"
            ),
            deviceTypeID: deviceType,
            localizedName: "Microphone",
            manufacturer: "Fixture",
            modelID: "microphone-1",
            position: .front,
            mediaTypes: [.audio],
            capabilityRevision: 1
        )
    }
}

private actor TestCaptureProvider: CaptureDeviceProvider {
    nonisolated let driverID: CaptureDriverID

    private let descriptors: [CaptureDeviceDescriptor]
    private let discoveryError: CaptureDriverError?
    private let requestedAuthorizationStatus: CaptureAuthorizationStatus
    private var currentAuthorizationStatus: CaptureAuthorizationStatus

    init(
        driverID: CaptureDriverID,
        descriptors: [CaptureDeviceDescriptor],
        authorizationStatus: CaptureAuthorizationStatus = .authorized,
        requestedAuthorizationStatus: CaptureAuthorizationStatus = .authorized,
        discoveryError: CaptureDriverError? = nil
    ) {
        self.driverID = driverID
        self.descriptors = descriptors
        self.currentAuthorizationStatus = authorizationStatus
        self.requestedAuthorizationStatus = requestedAuthorizationStatus
        self.discoveryError = discoveryError
    }

    func authorizationStatus(
        for mediaType: CaptureMediaTypeID
    ) async -> CaptureAuthorizationStatus {
        currentAuthorizationStatus
    }

    func requestAccess(
        for mediaType: CaptureMediaTypeID
    ) async throws(CaptureDriverError) -> CaptureAuthorizationStatus {
        currentAuthorizationStatus = requestedAuthorizationStatus
        return currentAuthorizationStatus
    }

    func devices(
        matching request: CaptureDiscoveryRequest
    ) async throws(CaptureDriverError) -> [CaptureDeviceDescriptor] {
        if let discoveryError {
            throw discoveryError
        }
        return descriptors
    }

    func deviceHandle(
        for deviceID: CaptureDeviceID
    ) async throws(CaptureDriverError) -> any CaptureDeviceHandle {
        throw .deviceNotFound(deviceID)
    }
}
