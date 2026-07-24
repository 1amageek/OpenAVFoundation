extension AVCaptureDevice {
    public final class DiscoverySession {
        public let devices: [AVCaptureDevice]

        init(devices: [AVCaptureDevice]) {
            self.devices = devices
        }
    }
}

#if !hasFeature(Embedded)
extension AVCaptureDevice.DiscoverySession: Sendable {}
#endif
