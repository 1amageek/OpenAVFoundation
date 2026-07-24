final class CaptureSessionSampleSink: CaptureSampleSink {
    private let delivery: VideoOutputDelivery
    private let connection: AVCaptureConnection

    init(
        delivery: VideoOutputDelivery,
        connection: AVCaptureConnection
    ) {
        self.delivery = delivery
        self.connection = connection
    }

    func offer(
        _ sampleBuffer: any CMSampleBuffer
    ) -> CaptureSampleDisposition {
        guard let output =
                connection.output as? AVCaptureVideoDataOutput else {
            return .stop
        }
        return delivery.offer(
            sampleBuffer,
            output: output,
            from: connection
        )
    }
}
