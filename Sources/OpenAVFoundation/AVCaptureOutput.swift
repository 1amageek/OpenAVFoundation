import Synchronization

public class AVCaptureOutput {
    private struct State: Sendable {
        var connections: [AVCaptureConnection] = []
        var ownerID: ObjectIdentifier?
    }

    private let state = Mutex(State())

    public init() {}

    public var connections: [AVCaptureConnection] {
        state.withLock { state in state.connections }
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
        state.withLock { state in
            state.connections = connections
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
