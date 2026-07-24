#if !hasFeature(Embedded)
import Synchronization
#endif

public class AVCaptureOutput {
    private struct State {
        var connections: [AVCaptureConnection] = []
        var ownerID: ObjectIdentifier?
    }

#if hasFeature(Embedded)
    private var state = State()
#else
    private let state = Mutex(State())
#endif

    public init() {}

    public var connections: [AVCaptureConnection] {
#if hasFeature(Embedded)
        state.connections
#else
        state.withLock { state in state.connections }
#endif
    }

    public func connection(
        with mediaType: AVMediaType
    ) -> AVCaptureConnection? {
        connections.first { connection in
            connection.inputPorts.contains {
                $0.mediaType == mediaType
            }
        }
    }

    func replaceConnections(
        _ connections: [AVCaptureConnection]
    ) {
#if hasFeature(Embedded)
        state.connections = connections
#else
        state.withLock { state in
            state.connections = connections
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
