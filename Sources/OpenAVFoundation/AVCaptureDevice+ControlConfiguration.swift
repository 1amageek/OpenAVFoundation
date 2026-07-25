extension AVCaptureDevice {
    public struct ControlConfiguration: Sendable, Hashable {
        public let deviceID: CaptureDeviceID
        public let capabilityRevision: UInt64
        public let controls: CaptureDeviceControls

        public init(
            deviceID: CaptureDeviceID,
            capabilityRevision: UInt64,
            controls: CaptureDeviceControls
        ) {
            self.deviceID = deviceID
            self.capabilityRevision = capabilityRevision
            self.controls = controls
        }
    }
}
