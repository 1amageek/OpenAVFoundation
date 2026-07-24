public final class AVCaptureConnection {
    public let inputPorts: [AVCaptureInput.Port]
#if hasFeature(Embedded)
    private let connectedOutput: AVCaptureOutput
#else
    private nonisolated(unsafe) weak var connectedOutput: AVCaptureOutput?
#endif

    public init(
        inputPorts ports: [AVCaptureInput.Port],
        output: AVCaptureOutput
    ) {
        inputPorts = ports
        connectedOutput = output
    }

    public var output: AVCaptureOutput? {
        connectedOutput
    }
}

#if !hasFeature(Embedded)
extension AVCaptureConnection: Sendable {}
#endif
