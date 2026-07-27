import Synchronization

public final class AVCaptureConnection {
    private struct State: Sendable {
        var videoConnectionConfiguration =
            CaptureVideoConnectionConfiguration.unchanged
    }

    public let inputPorts: [AVCaptureInput.Port]
    // Every target uses the same immutable strong reference. A committed graph
    // owns both endpoints and publishes the connection through output state.
    // Graph removal and graph deinitialization clear the output's connection
    // list before releasing endpoint ownership, breaking the temporary
    // output -> connection -> output retain cycle.
    private let connectedOutput: CaptureOutputReference
    private let state = Mutex(State())

    public init(
        inputPorts ports: [AVCaptureInput.Port],
        output: AVCaptureOutput
    ) {
        inputPorts = ports
        connectedOutput = CaptureOutputReference(value: output)
    }

    public var output: AVCaptureOutput? {
        connectedOutput.value
    }

    public var videoConnectionConfiguration:
        CaptureVideoConnectionConfiguration
    {
        get {
            state.withLock { state in
                state.videoConnectionConfiguration
            }
        }
        set {
            state.withLock { state in
                state.videoConnectionConfiguration = newValue
            }
        }
    }

    public var videoRotationAngle: Double? {
        get {
            state.withLock { state in
                state.videoConnectionConfiguration.rotationAngle?.rawValue
            }
        }
        set {
            guard let newValue else {
                state.withLock { state in
                    let current = state.videoConnectionConfiguration
                    state.videoConnectionConfiguration =
                        CaptureVideoConnectionConfiguration(
                            rotationAngle: nil,
                            stabilizationMode: current.stabilizationMode,
                            mirroringMode: current.mirroringMode
                        )
                }
                return
            }
            do {
                try setVideoRotationAngle(newValue)
            } catch {
                preconditionFailure("Invalid video rotation angle: \(error)")
            }
        }
    }

    public func isVideoRotationAngleSupported(_ angle: Double) -> Bool {
        guard let rotationAngle = CaptureVideoRotationAngle(rawValue: angle)
        else {
            return false
        }
        var foundDeviceInput = false
        for port in inputPorts where port.mediaType == .video {
            guard let input = port.input as? AVCaptureDeviceInput else {
                continue
            }
            foundDeviceInput = true
            if let supported = input.device.isVideoRotationAngleSupported(
                rotationAngle
            ) {
                return supported
            }
        }
        return foundDeviceInput
    }

    public func setVideoRotationAngle(
        _ angle: Double
    ) throws(AVCaptureConnectionError) {
        guard let rotationAngle = CaptureVideoRotationAngle(rawValue: angle)
        else {
            throw .invalidVideoRotationAngle(angle)
        }
        guard isVideoRotationAngleSupported(angle) else {
            throw .unsupportedVideoRotationAngle(angle)
        }
        state.withLock { state in
            let current = state.videoConnectionConfiguration
            state.videoConnectionConfiguration =
                CaptureVideoConnectionConfiguration(
                    rotationAngle: rotationAngle,
                    stabilizationMode: current.stabilizationMode,
                    mirroringMode: current.mirroringMode
                )
        }
    }

    public var preferredVideoStabilizationMode:
        CaptureVideoStabilizationMode
    {
        get {
            state.withLock { state in
                state.videoConnectionConfiguration.stabilizationMode
                    ?? .off
            }
        }
        set {
            state.withLock { state in
                let current = state.videoConnectionConfiguration
                state.videoConnectionConfiguration =
                    CaptureVideoConnectionConfiguration(
                        rotationAngle: current.rotationAngle,
                        stabilizationMode: newValue,
                        mirroringMode: current.mirroringMode
                    )
            }
        }
    }

    public var automaticallyAdjustsVideoMirroring: Bool {
        get {
            state.withLock { state in
                switch state.videoConnectionConfiguration.mirroringMode {
                case .none, .some(.automatic):
                    true
                case .some(.enabled), .some(.disabled):
                    false
                }
            }
        }
        set {
            state.withLock { state in
                let current = state.videoConnectionConfiguration
                let mirroringMode: CaptureVideoMirroringMode
                if newValue {
                    mirroringMode = .automatic
                } else if current.mirroringMode == .enabled {
                    mirroringMode = .enabled
                } else {
                    mirroringMode = .disabled
                }
                state.videoConnectionConfiguration =
                    CaptureVideoConnectionConfiguration(
                        rotationAngle: current.rotationAngle,
                        stabilizationMode: current.stabilizationMode,
                        mirroringMode: mirroringMode
                    )
            }
        }
    }

    public var isVideoMirrored: Bool {
        get {
            state.withLock { state in
                state.videoConnectionConfiguration.mirroringMode == .enabled
            }
        }
        set {
            state.withLock { state in
                let current = state.videoConnectionConfiguration
                state.videoConnectionConfiguration =
                    CaptureVideoConnectionConfiguration(
                        rotationAngle: current.rotationAngle,
                        stabilizationMode: current.stabilizationMode,
                        mirroringMode: newValue ? .enabled : .disabled
                    )
            }
        }
    }
}

extension AVCaptureConnection: Sendable {}
