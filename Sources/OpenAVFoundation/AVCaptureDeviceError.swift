public enum AVCaptureDeviceError: Error, Sendable, Equatable {
    case duplicateProvider(CaptureDriverID)
    case unknownProvider(CaptureDriverID)
    case unsupportedAuthorizationMediaType(AVMediaType)
    case invalidContract(CaptureContractError)
    case providerFailure(
        driverID: CaptureDriverID,
        error: CaptureDriverError
    )
    case providerReturnedForeignDevice(
        providerID: CaptureDriverID,
        deviceID: CaptureDeviceID
    )
    case duplicateDevice(CaptureDeviceID)
    case capabilitiesNotResolved(CaptureDeviceID)
    case capabilityDeviceMismatch(
        expected: CaptureDeviceID,
        actual: CaptureDeviceID
    )
    case capabilityRevisionMismatch(
        deviceID: CaptureDeviceID,
        expected: UInt64,
        actual: UInt64
    )
    case foreignFormat(
        expectedDeviceID: CaptureDeviceID,
        actualDeviceID: CaptureDeviceID
    )
    case staleFormat(
        deviceID: CaptureDeviceID,
        expectedRevision: UInt64,
        actualRevision: UInt64
    )
    case formatUnavailable(CaptureDeviceFormatID)
    case unsupportedFrameRate(
        formatID: CaptureDeviceFormatID,
        frameRate: Double
    )
    case foreignControls(
        expectedDeviceID: CaptureDeviceID,
        actualDeviceID: CaptureDeviceID
    )
    case staleControls(
        deviceID: CaptureDeviceID,
        expectedRevision: UInt64,
        actualRevision: UInt64
    )
    case invalidControlContract(CaptureContractError)
    case unsupportedControls(CaptureDriverError)
    case capabilityCleanupFailure(
        primary: CaptureDriverError,
        cleanup: CaptureDriverError
    )
}
