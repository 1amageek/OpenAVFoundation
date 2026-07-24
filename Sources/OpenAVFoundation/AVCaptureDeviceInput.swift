public final class AVCaptureDeviceInput: AVCaptureInput {
    public let device: AVCaptureDevice

    public init(
        device: AVCaptureDevice
    ) throws(AVCaptureDeviceInputError) {
        guard device.isConnected else {
            throw .deviceDisconnected(device.uniqueID)
        }
        guard !device.isSuspended else {
            throw .deviceSuspended(device.uniqueID)
        }

        var mediaTypes: [AVMediaType] = []
        mediaTypes.reserveCapacity(device.descriptor.mediaTypes.count)
        for mediaType in device.descriptor.mediaTypes {
            switch mediaType {
            case .video:
                mediaTypes.append(.video)
            case .audio:
                mediaTypes.append(.audio)
            case .metadata:
                mediaTypes.append(.metadata)
            default:
                mediaTypes.append(
                    AVMediaType(rawValue: mediaType.rawValue)
                )
            }
        }
        guard !mediaTypes.isEmpty else {
            throw .missingMediaPorts(device.uniqueID)
        }

        self.device = device
        super.init()
        installPorts(mediaTypes)
    }
}
