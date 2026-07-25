public protocol AVCaptureVideoDataOutputSampleBufferDelegate:
    AnyObject,
    Sendable
{
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: any CMSampleBuffer,
        from connection: AVCaptureConnection
    )

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop event: CaptureStreamDropEvent,
        from connection: AVCaptureConnection
    )
}

public extension AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop event: CaptureStreamDropEvent,
        from connection: AVCaptureConnection
    ) {}
}
