public enum AVCaptureSessionRuntimeEvent: Sendable, Equatable {
    case interrupted(CaptureStreamInterruption)
    case resumed
    case pressure(CaptureSystemPressure)
    case sourceDropped(CaptureStreamDropEvent)
    case failed(AVCaptureSessionRuntimeFailure)
}
