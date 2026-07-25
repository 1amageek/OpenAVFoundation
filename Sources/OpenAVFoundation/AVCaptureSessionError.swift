public enum AVCaptureSessionRuntimeFailure:
    Error,
    Sendable,
    Equatable
{
    case driver(
        operation: CaptureDriverOperation,
        error: CaptureDriverError
    )
    case contract(CaptureContractError)
    case deviceConfiguration(AVCaptureDeviceError)
    case snapshotDeviceMismatch(
        expected: CaptureDeviceID,
        actual: CaptureDeviceID
    )
    case snapshotRevisionMismatch(
        deviceID: CaptureDeviceID,
        expected: UInt64,
        actual: UInt64
    )
    case streamDeviceMismatch(
        expected: CaptureDeviceID,
        actual: CaptureDeviceID
    )
    case streamEventCapabilitiesMismatch(
        expected: CaptureStreamEventCapabilities,
        actual: CaptureStreamEventCapabilities
    )
    case undeclaredStreamEvent(CaptureStreamEvent)
}

public enum AVCaptureSessionError: Error, Sendable, Equatable {
    case configurationAlreadyActive
    case configurationNotActive
    case configurationWhileRunningUnsupported
    case configurationInProgress
    case sessionBusy
    case inputLimitReached
    case outputLimitReached
    case duplicateInput
    case duplicateOutput
    case inputOwnedByAnotherSession
    case outputOwnedByAnotherSession
    case unsupportedInput
    case unsupportedOutput
    case missingInput
    case missingOutput
    case missingVideoPort
    case incompatibleVideoConnectionConfigurations
    case runtime(AVCaptureSessionRuntimeFailure)
    case startRollbackFailure(
        primary: AVCaptureSessionRuntimeFailure,
        cleanupFailures: [CaptureDriverError]
    )
    case stopFailures([CaptureDriverError])
}
