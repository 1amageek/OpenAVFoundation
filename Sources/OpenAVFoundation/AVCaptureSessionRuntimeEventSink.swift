public protocol AVCaptureSessionRuntimeEventSink: AnyObject, Sendable {
    func offer(
        _ event: AVCaptureSessionRuntimeEvent
    ) -> AVCaptureSessionRuntimeEventDisposition
}
