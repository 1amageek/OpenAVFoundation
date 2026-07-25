extension AVCaptureDevice {
    public final class DiscoverySession: Sendable {
        public let devices: [AVCaptureDevice]

        init(devices: [AVCaptureDevice]) {
            self.devices = devices
        }
    }
}
