public enum AVCaptureVideoDataOutputDropReason:
    Sendable,
    Equatable
{
    case frameWasLate
    case queueFull
}
