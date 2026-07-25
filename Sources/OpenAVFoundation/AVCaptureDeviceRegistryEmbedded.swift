#if hasFeature(Embedded)
import Synchronization

/// A synchronized registry for statically composed Embedded Swift providers.
public final class AVCaptureDeviceRegistry: Sendable {
    private struct ProviderBox: Sendable {
        let driverID: CaptureDriverID
        let authorizationStatus:
            @Sendable (CaptureMediaTypeID) -> CaptureAuthorizationStatus
        let requestAccess:
            @Sendable (CaptureMediaTypeID)
                throws(CaptureDriverError) -> CaptureAuthorizationStatus
        let devices:
            @Sendable (CaptureDiscoveryRequest)
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

    private struct ProviderEntry: Sendable {
        let driverID: CaptureDriverID
        let box: ProviderBox
    }

    private struct DeviceEntry: Sendable {
        let deviceID: CaptureDeviceID
        let device: AVCaptureDevice
    }

    private struct State: Sendable {
        var providers: [ProviderEntry] = []
        var devices: [DeviceEntry] = []
    }

    private let state = Mutex(State())

    public init() {}

    public func register<Provider: CaptureDeviceProvider>(
        _ provider: Provider
    ) throws(AVCaptureDeviceError) {
        let providerBox = ProviderBox(provider)
        try state.withLock { state throws(AVCaptureDeviceError) in
            guard !state.providers.contains(where: {
                $0.driverID == providerBox.driverID
            }) else {
                throw .duplicateProvider(providerBox.driverID)
            }
            state.providers.append(
                ProviderEntry(
                    driverID: providerBox.driverID,
                    box: providerBox
                )
            )
        }
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
        var observedDeviceIDs: [CaptureDeviceID] = []

        let providers = state.withLock { state in
            var providers: [ProviderBox] = []
            providers.reserveCapacity(state.providers.count)
            for entry in state.providers {
                providers.append(entry.box)
            }
            return providers
        }
        for provider in providers {
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
                guard !observedDeviceIDs.contains(descriptor.deviceID) else {
                    throw .duplicateDevice(descriptor.deviceID)
                }
                observedDeviceIDs.append(descriptor.deviceID)
                discoveredDevices.append(
                    (descriptor: descriptor, opener: provider.handleOpener)
                )
            }
        }

        var resolved: [AVCaptureDevice] = []
        resolved.reserveCapacity(discoveredDevices.count)
        state.withLock { state in
            for discoveredDevice in discoveredDevices {
                let descriptor = discoveredDevice.descriptor
                if let existing = state.devices.first(where: {
                    $0.deviceID == descriptor.deviceID
                }),
                   existing.device.descriptor == descriptor {
                    resolved.append(existing.device)
                } else {
                    let device = AVCaptureDevice(
                        descriptor: descriptor,
                        handleOpener: discoveredDevice.opener
                    )
                    if let index = state.devices.firstIndex(where: {
                        $0.deviceID == descriptor.deviceID
                    }) {
                        state.devices[index] = DeviceEntry(
                            deviceID: descriptor.deviceID,
                            device: device
                        )
                    } else {
                        state.devices.append(
                            DeviceEntry(
                                deviceID: descriptor.deviceID,
                                device: device
                            )
                        )
                    }
                    resolved.append(device)
                }
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
        try state.withLock { state throws(AVCaptureDeviceError) in
            guard let provider = state.providers.first(where: {
                $0.driverID == driverID
            }) else {
                throw .unknownProvider(driverID)
            }
            return provider.box
        }
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
