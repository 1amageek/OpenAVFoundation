#if hasFeature(Embedded)
/// An owner-isolated registry for statically composed Embedded Swift providers.
public final class AVCaptureDeviceRegistry {
    private struct ProviderBox {
        let driverID: CaptureDriverID
        let authorizationStatus:
            (CaptureMediaTypeID) -> CaptureAuthorizationStatus
        let requestAccess:
            (CaptureMediaTypeID)
                throws(CaptureDriverError) -> CaptureAuthorizationStatus
        let devices:
            (CaptureDiscoveryRequest)
                throws(CaptureDriverError) -> [CaptureDeviceDescriptor]
        let handleOpener: CaptureDeviceHandleOpener

        init<Provider: CaptureDeviceProvider>(_ provider: Provider) {
            driverID = provider.driverID
            authorizationStatus = { mediaType in
                provider.authorizationStatus(for: mediaType)
            }
            requestAccess = {
                (mediaType: CaptureMediaTypeID)
                    throws(CaptureDriverError) -> CaptureAuthorizationStatus in
                try provider.requestAccess(for: mediaType)
            }
            devices = {
                (request: CaptureDiscoveryRequest)
                    throws(CaptureDriverError) -> [CaptureDeviceDescriptor] in
                try provider.devices(matching: request)
            }
            handleOpener = CaptureDeviceHandleOpener {
                (deviceID: CaptureDeviceID)
                    throws(CaptureDriverError)
                    -> any CaptureDeviceHandle in
                try provider.deviceHandle(for: deviceID)
            }
        }
    }

    private var providers: [CaptureDriverID: ProviderBox] = [:]
    private var providerOrder: [CaptureDriverID] = []
    private var devices: [CaptureDeviceID: AVCaptureDevice] = [:]

    public init() {}

    public func register<Provider: CaptureDeviceProvider>(
        _ provider: Provider
    ) throws(AVCaptureDeviceError) {
        let providerBox = ProviderBox(provider)
        guard providers[providerBox.driverID] == nil else {
            throw .duplicateProvider(providerBox.driverID)
        }
        providers[providerBox.driverID] = providerBox
        providerOrder.append(providerBox.driverID)
    }

    public func discoverySession(
        deviceTypes: [AVCaptureDevice.DeviceType],
        mediaType: AVMediaType?,
        position: AVCaptureDevice.Position
    ) throws(AVCaptureDeviceError) -> AVCaptureDevice.DiscoverySession {
        let request = try captureRequest(
            deviceTypes: deviceTypes,
            mediaType: mediaType,
            position: position
        )
        var discoveredDevices: [
            (descriptor: CaptureDeviceDescriptor, opener: CaptureDeviceHandleOpener)
        ] = []
        var observedDeviceIDs: Set<CaptureDeviceID> = []

        for driverID in providerOrder {
            guard let provider = providers[driverID] else {
                throw .unknownProvider(driverID)
            }
            let discovered: [CaptureDeviceDescriptor]
            do {
                discovered = try provider.devices(request)
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
                discoveredDevices.append(
                    (descriptor: descriptor, opener: provider.handleOpener)
                )
            }
        }

        var resolved: [AVCaptureDevice] = []
        resolved.reserveCapacity(discoveredDevices.count)
        for discoveredDevice in discoveredDevices {
            let descriptor = discoveredDevice.descriptor
            if let existing = devices[descriptor.deviceID],
               existing.descriptor == descriptor {
                resolved.append(existing)
            } else {
                let device = AVCaptureDevice(
                    descriptor: descriptor,
                    handleOpener: discoveredDevice.opener
                )
                devices[descriptor.deviceID] = device
                resolved.append(device)
            }
        }
        return AVCaptureDevice.DiscoverySession(devices: resolved)
    }

    public func authorizationStatus(
        for mediaType: AVMediaType,
        providerID: CaptureDriverID
    ) throws(AVCaptureDeviceError) -> AVAuthorizationStatus {
        let provider = try provider(for: providerID)
        let captureMediaType = try authorizationMediaType(mediaType)
        return AVAuthorizationStatus(
            provider.authorizationStatus(captureMediaType)
        )
    }

    public func requestAccess(
        for mediaType: AVMediaType,
        providerID: CaptureDriverID
    ) throws(AVCaptureDeviceError) -> Bool {
        let provider = try provider(for: providerID)
        let captureMediaType = try authorizationMediaType(mediaType)
        do {
            let status = try provider.requestAccess(captureMediaType)
            return status == .authorized
        } catch {
            throw .providerFailure(driverID: providerID, error: error)
        }
    }

    private func provider(
        for driverID: CaptureDriverID
    ) throws(AVCaptureDeviceError) -> ProviderBox {
        guard let provider = providers[driverID] else {
            throw .unknownProvider(driverID)
        }
        return provider
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

    private func authorizationMediaType(
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
