#if !hasFeature(Embedded)
import Synchronization
#endif

public final class AVCaptureVideoDataOutput: AVCaptureOutput {
    private let delivery = VideoOutputDelivery()

    public override init() {
        super.init()
    }

    public var sampleBufferDelegate:
        (any AVCaptureVideoDataOutputSampleBufferDelegate)?
    {
        delivery.delegate
    }

    public func setSampleBufferDelegate(
        _ sampleBufferDelegate:
            (any AVCaptureVideoDataOutputSampleBufferDelegate)?
    ) {
        delivery.delegate = sampleBufferDelegate
    }

    public var alwaysDiscardsLateVideoFrames: Bool {
        get {
            delivery.discardsLateSamples
        }
        set {
            delivery.discardsLateSamples = newValue
        }
    }

    var deliveryEndpoint: VideoOutputDelivery {
        delivery
    }
}

#if hasFeature(Embedded)
final class VideoOutputDelivery {
    var delegate: (any AVCaptureVideoDataOutputSampleBufferDelegate)?
    var discardsLateSamples = true

    func offer(
        _ sampleBuffer: any CMSampleBuffer,
        output: AVCaptureVideoDataOutput,
        from connection: AVCaptureConnection
    ) -> CaptureSampleDisposition {
        guard let delegate else {
            return .dropped
        }
        delegate.captureOutput(
            output,
            didOutput: sampleBuffer,
            from: connection
        )
        return .accepted
    }
}
#else
final class VideoOutputDelivery: Sendable {
    private struct State {
        var delegate: (any AVCaptureVideoDataOutputSampleBufferDelegate)?
        var discardsLateSamples = true
    }

    private let state = Mutex(State())

    var delegate: (any AVCaptureVideoDataOutputSampleBufferDelegate)? {
        get {
            state.withLock { state in state.delegate }
        }
        set {
            state.withLock { state in state.delegate = newValue }
        }
    }

    var discardsLateSamples: Bool {
        get {
            state.withLock { state in state.discardsLateSamples }
        }
        set {
            state.withLock { state in
                state.discardsLateSamples = newValue
            }
        }
    }

    func offer(
        _ sampleBuffer: any CMSampleBuffer,
        output: AVCaptureVideoDataOutput,
        from connection: AVCaptureConnection
    ) -> CaptureSampleDisposition {
        let delegate = state.withLock { state in
            state.delegate
        }
        guard let delegate else {
            return .dropped
        }
        delegate.captureOutput(
            output,
            didOutput: sampleBuffer,
            from: connection
        )
        return .accepted
    }
}
#endif
