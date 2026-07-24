extension AVCaptureDevice {
    public struct DeviceType: RawRepresentable, Sendable, Hashable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let builtInWideAngleCamera = DeviceType(
            rawValue: "AVCaptureDeviceTypeBuiltInWideAngleCamera"
        )
        public static let microphone = DeviceType(
            rawValue: "AVCaptureDeviceTypeMicrophone"
        )
        public static let external = DeviceType(
            rawValue: "AVCaptureDeviceTypeExternal"
        )
    }
}
