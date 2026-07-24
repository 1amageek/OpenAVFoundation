extension AVCaptureDevice {
    public enum Position: Int, Sendable, Hashable {
        case unspecified = 0
        case back = 1
        case front = 2

        init(_ position: CaptureDevicePosition) {
            switch position {
            case .unspecified, .external:
                self = .unspecified
            case .front:
                self = .front
            case .back:
                self = .back
            }
        }

        var capturePosition: CaptureDevicePosition {
            switch self {
            case .unspecified:
                .unspecified
            case .front:
                .front
            case .back:
                .back
            }
        }
    }
}
