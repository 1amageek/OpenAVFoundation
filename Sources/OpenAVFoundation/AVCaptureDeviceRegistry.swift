#if !hasFeature(Embedded)
public actor AVCaptureDeviceRegistry {
    private struct ProviderBox: Sendable {
        let driverID: CaptureDriverID
        let authorizationStatus:
            @Sendable (CaptureMediaTypeID) async -> CaptureAuthorizationStatus
        let requestAccess:
            @Sendable (CaptureMediaTypeID)
                async throws(CaptureDriverError) -> CaptureAuthorizationStatus
        let devices:
            @Sendable (CaptureDiscoveryRequest)
                async throws(CaptureDriverError) -> [CaptureDeviceDescriptor]
        let handleOpener: CaptureDeviceHandleOpener

        init<Provider: CaptureDeviceProvider>(_ provider: Provider) {
            driverID = provider.driverID
            authorizationStatus = { mediaType in
                await provider.authorizationStatus(for: mediaType)
            }
            requestAccess = {
                (mediaType: CaptureMediaTypeID)
                    async throws(CaptureDriverError) -> CaptureAuthorizationStatus in
                try await provider.requestAccess(for: mediaType)
            }
            devices = {
                (request: CaptureDiscoveryRequest)
                    async throws(CaptureDriverError)
                    -> [CaptureDeviceDescriptor] in
                try await provider.devices(matching: request)
            }
            handleOpener = CaptureDeviceHandleOpener {
                (deviceID: CaptureDeviceID)
                    async throws(CaptureDriverError)
                    -> any CaptureDeviceHandle in
                try await provider.deviceHandle(for: deviceID)
            }
        }
    }

    private struct State: Sendable {
        var providers: [CaptureDriverID: ProviderBox] = [:]
        var providerOrder: [CaptureDriverID] = []
        var devices: [CaptureDeviceID: AVCaptureDevice] = [:]
    }

    private var state = State()

    public init() {}

    public func register<Provider: CaptureDeviceProvider>(
        _ provider: Provider
    ) throws(AVCaptureDeviceError) {
        let providerBox = ProviderBox(provider)
        guard state.providers[providerBox.driverID] == nil else {
            throw .duplicateProvider(providerBox.driverID)
        }
        state.providers[providerBox.driverID] = providerBox
        state.providerOrder.append(providerBox.driverID)
    }

    public func discoverySession(
        deviceTypes: [AVCaptureDevice.DeviceType],
        mediaType: AVMediaType?,
        position: AVCaptureDevice.Position
    ) async throws(AVCaptureDeviceError) -> AVCaptureDevice.DiscoverySession {
        let request = try captureRequest(
            deviceTypes: deviceTypes,
            mediaType: mediaType,
            position: position
        )
        let providers = providerSnapshot()
        let discoveredDevices = try await Self.discoveredDevices(
            providers: providers,
            request: request
        )
        let devices = resolvedDevices(for: discoveredDevices)
        return AVCaptureDevice.DiscoverySession(devices: devices)
    }

    public func authorizationStatus(
        for mediaType: AVMediaType,
        providerID: CaptureDriverID
    ) async throws(AVCaptureDeviceError) -> AVAuthorizationStatus {
        let provider = try provider(for: providerID)
        let captureMediaType = try captureMediaType(mediaType)
        return AVAuthorizationStatus(
            await provider.authorizationStatus(captureMediaType)
        )
    }

    public func requestAccess(
        for mediaType: AVMediaType,
        providerID: CaptureDriverID
    ) async throws(AVCaptureDeviceError) -> Bool {
        let provider = try provider(for: providerID)
        let captureMediaType = try captureMediaType(mediaType)
        do {
            let status = try await provider.requestAccess(captureMediaType)
            return status == .authorized
        } catch {
            throw .providerFailure(driverID: providerID, error: error)
        }
    }

    private func providerSnapshot() -> [ProviderBox] {
        state.providerOrder.compactMap { state.providers[$0] }
    }

    private func provider(
        for driverID: CaptureDriverID
    ) throws(AVCaptureDeviceError) -> ProviderBox {
        guard let provider = state.providers[driverID] else {
            throw .unknownProvider(driverID)
        }
        return provider
    }

    private func resolvedDevices(
        for discoveredDevices: [DiscoveredDevice]
    ) -> [AVCaptureDevice] {
        var resolved: [AVCaptureDevice] = []
        resolved.reserveCapacity(discoveredDevices.count)

        for discoveredDevice in discoveredDevices {
            let descriptor = discoveredDevice.descriptor
            if let existing = state.devices[descriptor.deviceID],
               existing.descriptor == descriptor {
                resolved.append(existing)
            } else {
                let device = AVCaptureDevice(
                    descriptor: descriptor,
                    handleOpener: discoveredDevice.handleOpener
                )
                state.devices[descriptor.deviceID] = device
                resolved.append(device)
            }
        }
        return resolved
    }

    private struct DiscoveredDevice: Sendable {
        let descriptor: CaptureDeviceDescriptor
        let handleOpener: CaptureDeviceHandleOpener
    }

    private nonisolated static func discoveredDevices(
        providers: [ProviderBox],
        request: CaptureDiscoveryRequest
    ) async throws(AVCaptureDeviceError) -> [DiscoveredDevice] {
        var devices: [DiscoveredDevice] = []
        var observedDeviceIDs: Set<CaptureDeviceID> = []

        for provider in providers {
            let discovered: [CaptureDeviceDescriptor]
            do {
                discovered = try await provider.devices(request)
            } catch {
                throw .providerFailure(
                    driverID: provider.driverID,
                    error: error
                )
            }

            for descriptor in discovered {
                guard descriptor.deviceID.driverID == provider.driverID else {
                    throw .providerReturnedForeignDevice(
                        providerID: provider.driverID,
                        deviceID: descriptor.deviceID
                    )
                }
                guard request.includes(descriptor) else {
                    continue
                }
                guard observedDeviceIDs.insert(descriptor.deviceID).inserted else {
                    throw .duplicateDevice(descriptor.deviceID)
                }
                devices.append(
                    DiscoveredDevice(
                        descriptor: descriptor,
                        handleOpener: provider.handleOpener
                    )
                )
            }
        }
        return devices
    }

    private func captureRequest(
        deviceTypes: [AVCaptureDevice.DeviceType],
        mediaType: AVMediaType?,
        position: AVCaptureDevice.Position
    ) throws(AVCaptureDeviceError) -> CaptureDiscoveryRequest {
        var captureDeviceTypes: [CaptureDeviceTypeID] = []
        captureDeviceTypes.reserveCapacity(deviceTypes.count)
        for deviceType in deviceTypes {
            do {
                captureDeviceTypes.append(
                    try CaptureDeviceTypeID(deviceType.rawValue)
                )
            } catch {
                throw .invalidContract(error)
            }
        }

        let selection: CaptureDeviceTypeSelection
        do {
            selection = try CaptureDeviceTypeSelection(
                matching: captureDeviceTypes
            )
        } catch {
            throw .invalidContract(error)
        }

        let requestedMediaType: CaptureMediaTypeID?
        if let mediaType {
            requestedMediaType = try validatedCaptureMediaType(mediaType)
        } else {
            requestedMediaType = nil
        }
        return CaptureDiscoveryRequest(
            deviceTypeSelection: selection,
            mediaType: requestedMediaType,
            position: position.capturePosition
        )
    }

    private func captureMediaType(
        _ mediaType: AVMediaType
    ) throws(AVCaptureDeviceError) -> CaptureMediaTypeID {
        guard mediaType == .video || mediaType == .audio else {
            throw .unsupportedAuthorizationMediaType(mediaType)
        }
        return try validatedCaptureMediaType(mediaType)
    }

    private func validatedCaptureMediaType(
        _ mediaType: AVMediaType
    ) throws(AVCaptureDeviceError) -> CaptureMediaTypeID {
        do {
            return try CaptureMediaTypeID(mediaType.captureRawValue)
        } catch {
            throw .invalidContract(error)
        }
    }
}
#endif

extension CaptureDiscoveryRequest {
    func includes(_ descriptor: CaptureDeviceDescriptor) -> Bool {
        guard deviceTypeSelection.includes(descriptor.deviceTypeID) else {
            return false
        }
        if let mediaType, !descriptor.mediaTypes.contains(mediaType) {
            return false
        }
        switch position {
        case .unspecified:
            return true
        case .front, .back, .external:
            return descriptor.position == position
        }
    }
}
