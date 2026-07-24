#if hasFeature(Embedded)
public protocol AVCaptureVideoDataOutputSampleBufferDelegate: AnyObject {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: any CMSampleBuffer,
        from connection: AVCaptureConnection
    )
}
#else
public protocol AVCaptureVideoDataOutputSampleBufferDelegate:
    AnyObject,
    Sendable
{
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: any CMSampleBuffer,
        from connection: AVCaptureConnection
    )
}
#endif
