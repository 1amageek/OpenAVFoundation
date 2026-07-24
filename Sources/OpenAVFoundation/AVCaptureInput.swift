#if !hasFeature(Embedded)
import Synchronization
#endif

public class AVCaptureInput {
    public final class Port {
#if hasFeature(Embedded)
        // Embedded Swift has no weak references. Owner isolation requires a
        // port not to outlive the input that vends it.
        private unowned(unsafe) let sourceInput: AVCaptureInput
#else
        private nonisolated(unsafe) weak var sourceInput: AVCaptureInput?
#endif
        private let state: PortState
        public let mediaType: AVMediaType

        init(
            input: AVCaptureInput,
            mediaType: AVMediaType,
            state: PortState
        ) {
            sourceInput = input
            self.mediaType = mediaType
            self.state = state
        }

        public var input: AVCaptureInput {
#if hasFeature(Embedded)
            sourceInput
#else
            guard let sourceInput else {
                preconditionFailure(
                    "An AVCaptureInput.Port must not outlive its input."
                )
            }
            return sourceInput
#endif
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
#if hasFeature(Embedded)
        var isEnabled = true
#else
        private let enabled = Mutex(true)

        var isEnabled: Bool {
            get {
                enabled.withLock { value in value }
            }
            set {
                enabled.withLock { value in value = newValue }
            }
        }
#endif
    }

    private struct State {
        var ports: [Port] = []
        var ownerID: ObjectIdentifier?
    }

#if hasFeature(Embedded)
    private var state = State()
#else
    private let state = Mutex(State())
#endif

    init() {}

    public var ports: [Port] {
#if hasFeature(Embedded)
        state.ports
#else
        state.withLock { state in state.ports }
#endif
    }

    func installPorts(_ mediaTypes: [AVMediaType]) {
        let ports = mediaTypes.map {
            Port(input: self, mediaType: $0, state: PortState())
        }
#if hasFeature(Embedded)
        precondition(state.ports.isEmpty)
        state.ports = ports
#else
        state.withLock { state in
            precondition(state.ports.isEmpty)
            state.ports = ports
        }
#endif
    }

    func canBeOwned(by ownerID: ObjectIdentifier) -> Bool {
#if hasFeature(Embedded)
        state.ownerID == nil || state.ownerID == ownerID
#else
        state.withLock { state in
            state.ownerID == nil || state.ownerID == ownerID
        }
#endif
    }

    func claimOwnership(
        by ownerID: ObjectIdentifier
    ) -> Bool {
#if hasFeature(Embedded)
        guard state.ownerID == nil || state.ownerID == ownerID else {
            return false
        }
        state.ownerID = ownerID
        return true
#else
        state.withLock { state in
            guard state.ownerID == nil || state.ownerID == ownerID else {
                return false
            }
            state.ownerID = ownerID
            return true
        }
#endif
    }

    func releaseOwnership(
        by ownerID: ObjectIdentifier
    ) {
#if hasFeature(Embedded)
        if state.ownerID == ownerID {
            state.ownerID = nil
        }
#else
        state.withLock { state in
            if state.ownerID == ownerID {
                state.ownerID = nil
            }
        }
#endif
    }
}

#if !hasFeature(Embedded)
extension AVCaptureInput.Port: Sendable {}
extension AVCaptureInput.PortState: Sendable {}
#endif
