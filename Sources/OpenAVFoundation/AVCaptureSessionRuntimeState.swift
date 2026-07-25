public enum AVCaptureSessionRuntimeState: Sendable, Equatable {
    case idle
    case starting
    case running
    case interrupted(CaptureStreamInterruption)
    case stopping
    case cleanupRequired([CaptureDriverError])
    case failed(AVCaptureSessionRuntimeFailure)
}
