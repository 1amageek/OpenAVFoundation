public final class AVCaptureDevice: Hashable {
    let descriptor: CaptureDeviceDescriptor
    let captureDeviceID: CaptureDeviceID
    let handleOpener: CaptureDeviceHandleOpener

    init(
        descriptor: CaptureDeviceDescriptor,
        handleOpener: CaptureDeviceHandleOpener
    ) {
        captureDeviceID = descriptor.deviceID
        self.descriptor = descriptor
        self.handleOpener = handleOpener
    }

    public static func == (lhs: AVCaptureDevice, rhs: AVCaptureDevice) -> Bool {
        lhs.captureDeviceID == rhs.captureDeviceID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(captureDeviceID)
    }

    public var uniqueID: String {
        let driverNamespace = captureDeviceID.driverID.rawValue
        return "\(driverNamespace.utf8.count)#\(driverNamespace)\(captureDeviceID.localID)"
    }

    public var modelID: String {
        descriptor.modelID
    }

    public var localizedName: String {
        descriptor.localizedName
    }

    public var manufacturer: String {
        descriptor.manufacturer
    }

    public var deviceType: DeviceType {
        DeviceType(rawValue: descriptor.deviceTypeID.rawValue)
    }

    public var position: Position {
        Position(descriptor.position)
    }

    public var isConnected: Bool {
        descriptor.isConnected
    }

    public var isSuspended: Bool {
        descriptor.isSuspended
    }

    public func hasMediaType(_ mediaType: AVMediaType) -> Bool {
        descriptor.mediaTypes.contains {
            $0.rawValue == mediaType.captureRawValue
        }
    }
}

#if !hasFeature(Embedded)
extension AVCaptureDevice: Sendable {}
#endif
