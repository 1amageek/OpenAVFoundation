extension AVCaptureDevice {
    public final class Format: Hashable, Sendable {
        let deviceID: CaptureDeviceID
        let capabilityRevision: UInt64
        let descriptor: CaptureDeviceFormatDescriptor

        init(
            deviceID: CaptureDeviceID,
            capabilityRevision: UInt64,
            descriptor: CaptureDeviceFormatDescriptor
        ) {
            self.deviceID = deviceID
            self.capabilityRevision = capabilityRevision
            self.descriptor = descriptor
        }

        public static func == (lhs: Format, rhs: Format) -> Bool {
            lhs.deviceID == rhs.deviceID
                && lhs.capabilityRevision == rhs.capabilityRevision
                && lhs.descriptor == rhs.descriptor
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(deviceID)
            hasher.combine(capabilityRevision)
            hasher.combine(descriptor)
        }

        public var formatID: CaptureDeviceFormatID {
            descriptor.formatID
        }

        public var mediaType: AVMediaType {
            AVMediaType(rawValue: descriptor.mediaType.rawValue)
        }

        public var mediaSubtype: UInt32 {
            descriptor.mediaSubtype.rawValue
        }

        public var dimensions: CaptureDimensions? {
            descriptor.dimensions
        }

        public var videoSupportedFrameRateRanges: [AVFrameRateRange] {
            descriptor.frameRateRanges.map { range in
                AVFrameRateRange(
                    minimum: range.minimum,
                    maximum: range.maximum
                )
            }
        }
    }
}
