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
}
