import Synchronization

public class AVCaptureInput {
    public final class Port {
#if hasFeature(Embedded)
        private final class InputReference: Sendable {
            // Embedded Swift has no weak references. The input owns every port
            // it vends, and a port must not escape that input's lifetime.
            // Valid Embedded capture graphs retain the input before reading
            // this immutable reference.
            nonisolated(unsafe) unowned(unsafe) let value: AVCaptureInput

            init(_ value: AVCaptureInput) {
                self.value = value
            }

            var resolvedValue: AVCaptureInput? {
                value
            }
        }
#else
        private final class InputReference: Sendable {
            // Native/WASM weak storage prevents the input -> port ->
            // input cycle. The reference is assigned only during
            // initialization; runtime zeroing is observed through
            // resolvedValue, and the stable-port release test verifies that
            // this wrapper does not extend the input lifetime.
            nonisolated(unsafe) weak var value: AVCaptureInput?

            init(_ value: AVCaptureInput) {
                self.value = value
            }

            var resolvedValue: AVCaptureInput? {
                value
            }
        }
#endif
        private let sourceInput: InputReference
        private let state: PortState
        public let mediaType: AVMediaType

        init(
            input: AVCaptureInput,
            mediaType: AVMediaType,
            state: PortState
        ) {
            sourceInput = InputReference(input)
            self.mediaType = mediaType
            self.state = state
        }

        public var input: AVCaptureInput {
            let input = sourceInput.resolvedValue
            guard let input else {
                preconditionFailure(
                    "An AVCaptureInput.Port must not outlive its input."
                )
            }
            return input
        }

        public var isEnabled: Bool {
            get {
                state.isEnabled
            }
            set {
                state.isEnabled = newValue
            }
        }
    }

    final class PortState {
        private let enabled = Mutex(true)

        var isEnabled: Bool {
            get {
                enabled.withLock { value in value }
            }
            set {
                enabled.withLock { value in value = newValue }
            }
        }
    }

    private struct State: Sendable {
        var ports: [Port] = []
        var ownerID: ObjectIdentifier?
    }

    private let state = Mutex(State())

    init() {}

    public var ports: [Port] {
        state.withLock { state in state.ports }
    }

    func installPorts(_ mediaTypes: [AVMediaType]) {
        let ports = mediaTypes.map {
            Port(input: self, mediaType: $0, state: PortState())
        }
        state.withLock { state in
            precondition(state.ports.isEmpty)
            state.ports = ports
        }
    }

    func canBeOwned(by ownerID: ObjectIdentifier) -> Bool {
        state.withLock { state in
            state.ownerID == nil || state.ownerID == ownerID
        }
    }

    func claimOwnership(
        by ownerID: ObjectIdentifier
    ) -> Bool {
        state.withLock { state in
            guard state.ownerID == nil || state.ownerID == ownerID else {
                return false
            }
            state.ownerID = ownerID
            return true
        }
    }

    func releaseOwnership(
        by ownerID: ObjectIdentifier
    ) {
        state.withLock { state in
            if state.ownerID == ownerID {
                state.ownerID = nil
            }
        }
    }
}

extension AVCaptureInput.Port: Sendable {}
extension AVCaptureInput.PortState: Sendable {}
