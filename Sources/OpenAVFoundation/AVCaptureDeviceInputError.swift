public enum AVCaptureDeviceInputError: Error, Sendable, Equatable {
    case deviceDisconnected(String)
    case deviceSuspended(String)
    case missingMediaPorts(String)
}
