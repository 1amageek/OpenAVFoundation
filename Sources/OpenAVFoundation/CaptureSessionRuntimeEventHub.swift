import Synchronization

final class CaptureSessionRuntimeEventHub:
    CaptureStreamEventSink,
    Sendable
{
    private struct State: Sendable {
        var runtimeState = AVCaptureSessionRuntimeState.idle
        var pressure: CaptureSystemPressure?
        var lastSourceDrop: CaptureStreamDropEvent?
        var sink: (any AVCaptureSessionRuntimeEventSink)?
        var routes: [CaptureSessionOutputRoute] = []
        var eventCapabilities: CaptureStreamEventCapabilities = []
    }

    private let state = Mutex(State())

    var runtimeState: AVCaptureSessionRuntimeState {
        state.withLock { state in state.runtimeState }
    }

    var pressure: CaptureSystemPressure? {
        state.withLock { state in state.pressure }
    }

    var lastSourceDrop: CaptureStreamDropEvent? {
        state.withLock { state in state.lastSourceDrop }
    }

    var isActive: Bool {
        state.withLock { state in
            switch state.runtimeState {
            case .running, .interrupted:
                true
            case .idle, .starting, .stopping, .cleanupRequired, .failed:
                false
            }
        }
    }

    func setSink(_ sink: (any AVCaptureSessionRuntimeEventSink)?) {
        state.withLock { state in state.sink = sink }
    }

    func beginStart(routes: [CaptureSessionOutputRoute]) {
        state.withLock { state in
            state.runtimeState = .starting
            state.pressure = nil
            state.lastSourceDrop = nil
            state.routes = routes
            state.eventCapabilities = []
        }
    }

    func finishStart(cleanupFailures: [CaptureDriverError]?) {
        state.withLock { state in
            if let cleanupFailures {
                state.runtimeState = .cleanupRequired(cleanupFailures)
                return
            }
            state.runtimeState = .idle
            state.pressure = nil
            state.lastSourceDrop = nil
            state.routes = []
            state.eventCapabilities = []
        }
    }

    func finishStartSuccessfully() {
        state.withLock { state in
            guard state.runtimeState == .starting else {
                return
            }
            state.runtimeState = .running
        }
    }

    func beginStop() {
        state.withLock { state in state.runtimeState = .stopping }
    }

    func finishStop(cleanupFailures: [CaptureDriverError]?) {
        state.withLock { state in
            if let cleanupFailures {
                state.runtimeState = .cleanupRequired(cleanupFailures)
                return
            }
            state.runtimeState = .idle
            state.pressure = nil
            state.lastSourceDrop = nil
            state.routes = []
            state.eventCapabilities = []
        }
    }

    func setEventCapabilities(
        _ capabilities: CaptureStreamEventCapabilities
    ) {
        state.withLock { state in
            state.eventCapabilities = capabilities
        }
    }

    func offer(
        _ event: CaptureStreamEvent
    ) -> CaptureStreamEventDisposition {
        let translated = Self.translated(event)
        let delivery = state.withLock {
            state -> (
                sink: (any AVCaptureSessionRuntimeEventSink)?,
                shouldDeliver: Bool,
                routes: [CaptureSessionOutputRoute],
                event: AVCaptureSessionRuntimeEvent
            ) in
            if case .failed = state.runtimeState {
                return (nil, false, [], translated)
            }
            switch state.runtimeState {
            case .starting, .running, .interrupted:
                break
            case .idle, .stopping, .cleanupRequired, .failed:
                return (nil, false, [], translated)
            }
            guard state.eventCapabilities.contains(
                Self.requiredCapability(for: event)
            ) else {
                let failure =
                    AVCaptureSessionRuntimeFailure.undeclaredStreamEvent(event)
                let failureEvent =
                    AVCaptureSessionRuntimeEvent.failed(failure)
                state.runtimeState = .failed(failure)
                return (state.sink, true, [], failureEvent)
            }

            switch translated {
            case let .interrupted(reason):
                switch state.runtimeState {
                case .starting, .running, .interrupted:
                    state.runtimeState = .interrupted(reason)
                case .idle, .stopping, .cleanupRequired, .failed:
                    return (nil, false, [], translated)
                }
            case .resumed:
                switch state.runtimeState {
                case .interrupted:
                    state.runtimeState = .running
                case .starting, .running:
                    break
                case .idle, .stopping, .cleanupRequired, .failed:
                    return (nil, false, [], translated)
                }
            case let .pressure(pressure):
                switch state.runtimeState {
                case .starting, .running, .interrupted:
                    state.pressure = pressure
                case .idle, .stopping, .cleanupRequired, .failed:
                    return (nil, false, [], translated)
                }
            case let .sourceDropped(drop):
                switch state.runtimeState {
                case .starting, .running, .interrupted:
                    state.lastSourceDrop = drop
                case .idle, .stopping, .cleanupRequired, .failed:
                    return (nil, false, [], translated)
                }
            case let .failed(failure):
                switch state.runtimeState {
                case .starting, .running, .interrupted:
                    state.runtimeState = .failed(failure)
                case .idle, .stopping, .cleanupRequired, .failed:
                    return (nil, false, [], translated)
                }
            }
            let routes: [CaptureSessionOutputRoute]
            if case .sourceDropped = translated {
                routes = state.routes
            } else {
                routes = []
            }
            return (state.sink, true, routes, translated)
        }

        guard delivery.shouldDeliver else {
            return .stop
        }
        for route in delivery.routes {
            guard let output =
                    route.connection.output as? AVCaptureVideoDataOutput,
                  case let .sourceDropped(drop) = delivery.event
            else {
                return .stop
            }
            route.delivery.notifySourceDrop(
                drop,
                output: output,
                from: route.connection
            )
        }
        guard let sink = delivery.sink else {
            if case .failed = delivery.event {
                return .stop
            }
            return .continueStreaming
        }
        switch sink.offer(delivery.event) {
        case .continueMonitoring:
            if case .failed = delivery.event {
                return .stop
            }
            return .continueStreaming
        case .stop:
            state.withLock { state in
                switch state.runtimeState {
                case .starting, .running, .interrupted:
                    state.runtimeState = .cleanupRequired([])
                case .idle, .stopping, .cleanupRequired, .failed:
                    break
                }
            }
            return .stop
        }
    }

    private static func translated(
        _ event: CaptureStreamEvent
    ) -> AVCaptureSessionRuntimeEvent {
        switch event {
        case let .interrupted(reason):
            .interrupted(reason)
        case .resumed:
            .resumed
        case let .pressure(pressure):
            .pressure(pressure)
        case let .dropped(drop):
            .sourceDropped(drop)
        case let .failed(error):
            .failed(.driver(operation: .streaming, error: error))
        }
    }

    private static func requiredCapability(
        for event: CaptureStreamEvent
    ) -> CaptureStreamEventCapabilities {
        switch event {
        case .interrupted, .resumed:
            .interruptions
        case .pressure:
            .systemPressure
        case .dropped:
            .sourceDrops
        case .failed:
            .terminalFailures
        }
    }
}
