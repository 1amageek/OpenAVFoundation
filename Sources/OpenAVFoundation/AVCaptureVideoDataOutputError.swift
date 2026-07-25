public enum AVCaptureVideoDataOutputError:
    Error,
    Sendable,
    Equatable
{
    case invalidPendingSampleLimit(Int)
}
