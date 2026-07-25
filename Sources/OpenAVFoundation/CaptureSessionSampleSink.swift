final class CaptureSessionSampleSink: CaptureSampleSink {
    private let routes: [CaptureSessionOutputRoute]

    init(
        routes: [CaptureSessionOutputRoute]
    ) {
        precondition(!routes.isEmpty)
        self.routes = routes
    }

    func offer(
        _ sampleBuffer: any CMSampleBuffer
    ) -> CaptureSampleDisposition {
        var accepted = false
        for route in routes {
            guard let output =
                    route.connection.output as? AVCaptureVideoDataOutput else {
                return .stop
            }
            switch route.delivery.offer(
                sampleBuffer,
                output: output,
                from: route.connection
            ) {
            case .accepted:
                accepted = true
            case .dropped:
                break
            case .stop:
                return .stop
            }
        }
        return accepted ? .accepted : .dropped
    }
}
