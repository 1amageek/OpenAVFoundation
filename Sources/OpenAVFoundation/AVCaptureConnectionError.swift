public enum AVCaptureConnectionError: Error, Sendable, Equatable {
    case invalidVideoRotationAngle(Double)
    case unsupportedVideoRotationAngle(Double)
}
