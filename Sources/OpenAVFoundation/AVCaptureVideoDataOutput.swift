import Synchronization

public final class AVCaptureVideoDataOutput: AVCaptureOutput {
    /// The largest portable queue bound accepted by
    /// ``setPendingSampleLimit(_:)``.
    ///
    /// Pending entries retain their media-buffer leases. Keeping this bound
    /// small prevents a slow delegate from pinning an application-scale amount
    /// of camera memory while still allowing explicitly buffered consumers.
    public static let maximumPendingSampleLimit = 8

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

    /// The maximum number of samples queued behind an active delegate call.
    ///
    /// This is a portable bounded-backpressure extension. Apple AVFoundation
    /// does not expose a queue-capacity property. The portable maximum is
    /// 8 pending samples.
    public var pendingSampleLimit: Int {
        delivery.pendingSampleLimit
    }

    public func setPendingSampleLimit(
        _ limit: Int
    ) throws(AVCaptureVideoDataOutputError) {
        try delivery.setPendingSampleLimit(limit)
    }

    public var droppedSampleCount: UInt64 {
        delivery.droppedSampleCount
    }

    public var lastDropReason: AVCaptureVideoDataOutputDropReason? {
        delivery.lastDropReason
    }

    var deliveryEndpoint: VideoOutputDelivery {
        delivery
    }
}

final class VideoOutputDelivery: Sendable {
    private struct SampleDelivery: Sendable {
        // Reuse the graph's single audited immutable output-reference boundary.
        // The circular slot owns this reference only until dequeue and callback
        // completion; no media bytes or pointers are copied into the item.
        let output: CaptureOutputReference
        let delegate: any AVCaptureVideoDataOutputSampleBufferDelegate
        let sampleBuffer: any CMSampleBuffer
        let connection: AVCaptureConnection
    }

    private struct SourceDropDelivery: Sendable {
        let output: CaptureOutputReference
        let delegate: any AVCaptureVideoDataOutputSampleBufferDelegate
        let event: CaptureStreamDropEvent
        let connection: AVCaptureConnection
    }

    private enum DeliveryItem: Sendable {
        case sample(SampleDelivery)
        case sourceDrop(SourceDropDelivery)

        var isSample: Bool {
            if case .sample = self {
                return true
            }
            return false
        }
    }

    private enum OfferDecision: Sendable {
        case start(DeliveryItem)
        case accepted
        case dropped
    }

    private struct State: Sendable {
        var delegate: (any AVCaptureVideoDataOutputSampleBufferDelegate)?
        var discardsLateSamples = true
        var pendingSampleLimit = 1
        // One additional metadata-only slot serializes a source-drop callback
        // with sample callbacks without reducing the configured sample bound.
        var pendingSlots: [DeliveryItem?] = [nil, nil]
        var pendingHead = 0
        var pendingCount = 0
        var pendingSampleCount = 0
        var hasPendingSourceDrop = false
        var isDelivering = false
        var droppedSampleCount: UInt64 = 0
        var lastDropReason: AVCaptureVideoDataOutputDropReason?
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

    var pendingSampleLimit: Int {
        state.withLock { state in state.pendingSampleLimit }
    }

    func setPendingSampleLimit(
        _ limit: Int
    ) throws(AVCaptureVideoDataOutputError) {
        guard limit >= 0,
              limit <= AVCaptureVideoDataOutput.maximumPendingSampleLimit else {
            throw .invalidPendingSampleLimit(limit)
        }
        let capacity = limit.addingReportingOverflow(1)
        guard !capacity.overflow else {
            throw .invalidPendingSampleLimit(limit)
        }
        let replacement = [DeliveryItem?](
            repeating: nil,
            count: capacity.partialValue
        )
        let released = state.withLock { state -> [DeliveryItem?] in
            let previous = state.pendingSlots
            let previousCount = state.pendingCount
            let previousHead = state.pendingHead

            state.pendingSlots = consume replacement
            state.pendingHead = 0
            state.pendingCount = 0
            state.pendingSampleCount = 0
            state.hasPendingSourceDrop = false
            state.pendingSampleLimit = limit

            for offset in 0..<previousCount {
                let index = Self.wrappedIndex(
                    start: previousHead,
                    offset: offset,
                    count: previous.count
                )
                guard let item = previous[index] else {
                    preconditionFailure(
                        "Delivery queue storage is inconsistent"
                    )
                }
                if item.isSample,
                   state.pendingSampleCount >= limit {
                    Self.recordDrop(.queueFull, state: &state)
                    continue
                }
                if case .sourceDrop = item,
                   state.hasPendingSourceDrop {
                    continue
                }
                precondition(Self.enqueue(item, state: &state))
                if item.isSample {
                    state.pendingSampleCount += 1
                } else {
                    state.hasPendingSourceDrop = true
                }
            }
            return previous
        }
        // Release evicted sample leases only after leaving the delivery mutex.
        withExtendedLifetime(released) {}
    }

    var droppedSampleCount: UInt64 {
        state.withLock { state in state.droppedSampleCount }
    }

    var lastDropReason: AVCaptureVideoDataOutputDropReason? {
        state.withLock { state in state.lastDropReason }
    }

    func offer(
        _ sampleBuffer: any CMSampleBuffer,
        output: AVCaptureVideoDataOutput,
        from connection: AVCaptureConnection
    ) -> CaptureSampleDisposition {
        let decision = state.withLock { state -> OfferDecision in
            guard let delegate = state.delegate else {
                return .dropped
            }

            let item = DeliveryItem.sample(SampleDelivery(
                output: CaptureOutputReference(value: output),
                delegate: delegate,
                sampleBuffer: sampleBuffer,
                connection: connection
            ))
            guard state.isDelivering else {
                state.isDelivering = true
                return .start(item)
            }
            if state.discardsLateSamples {
                Self.recordDrop(.frameWasLate, state: &state)
                return .dropped
            }
            guard state.pendingSampleCount < state.pendingSampleLimit,
                  Self.enqueue(item, state: &state) else {
                Self.recordDrop(.queueFull, state: &state)
                return .dropped
            }
            state.pendingSampleCount += 1
            return .accepted
        }

        switch decision {
        case .start(let item):
            drain(startingWith: item)
            return .accepted
        case .accepted:
            return .accepted
        case .dropped:
            return .dropped
        }
    }

    func notifySourceDrop(
        _ event: CaptureStreamDropEvent,
        output: AVCaptureVideoDataOutput,
        from connection: AVCaptureConnection
    ) {
        let item = state.withLock { state -> DeliveryItem? in
            guard let delegate = state.delegate else {
                return nil
            }
            let item = DeliveryItem.sourceDrop(SourceDropDelivery(
                output: CaptureOutputReference(value: output),
                delegate: delegate,
                event: event,
                connection: connection
            ))
            guard state.isDelivering else {
                state.isDelivering = true
                return item
            }

            // The event carries a cumulative source-drop count. Keep only the
            // newest pending event, at its correct position after samples that
            // arrived since the previous event.
            if state.hasPendingSourceDrop {
                Self.removePendingSourceDrop(state: &state)
            }
            precondition(Self.enqueue(item, state: &state))
            state.hasPendingSourceDrop = true
            return nil
        }
        if let item {
            drain(startingWith: item)
        }
    }

    private func drain(startingWith first: DeliveryItem) {
        var current: DeliveryItem? = first
        while let item = current {
            Self.deliver(item)
            current = state.withLock { state -> DeliveryItem? in
                guard let item = Self.dequeue(state: &state) else {
                    state.isDelivering = false
                    return nil
                }
                return item
            }
        }
    }

    private static func deliver(_ item: DeliveryItem) {
        switch item {
        case .sample(let sample):
            sample.delegate.captureOutput(
                sample.output.value,
                didOutput: sample.sampleBuffer,
                from: sample.connection
            )
        case .sourceDrop(let drop):
            drop.delegate.captureOutput(
                drop.output.value,
                didDrop: drop.event,
                from: drop.connection
            )
        }
    }

    private static func enqueue(
        _ item: DeliveryItem,
        state: inout State
    ) -> Bool {
        guard state.pendingCount < state.pendingSlots.count else {
            return false
        }

        let insertionIndex = wrappedIndex(
            start: state.pendingHead,
            offset: state.pendingCount,
            count: state.pendingSlots.count
        )
        precondition(state.pendingSlots[insertionIndex] == nil)
        state.pendingSlots[insertionIndex] = item
        let (nextCount, overflow) =
            state.pendingCount.addingReportingOverflow(1)
        guard !overflow else {
            state.pendingSlots[insertionIndex] = nil
            return false
        }
        state.pendingCount = nextCount
        return true
    }

    private static func dequeue(
        state: inout State
    ) -> DeliveryItem? {
        guard state.pendingCount > 0 else {
            return nil
        }
        let index = state.pendingHead
        guard let item = state.pendingSlots[index] else {
            preconditionFailure("Delivery queue storage is inconsistent")
        }
        // Clear the slot before invoking external code so the queue never
        // extends a completed sample lease. The local item owns the sample
        // only for the duration of the delegate call.
        state.pendingSlots[index] = nil
        state.pendingHead =
            index == state.pendingSlots.count - 1 ? 0 : index + 1
        state.pendingCount -= 1
        if item.isSample {
            precondition(state.pendingSampleCount > 0)
            state.pendingSampleCount -= 1
        } else {
            precondition(state.hasPendingSourceDrop)
            state.hasPendingSourceDrop = false
        }
        return item
    }

    private static func removePendingSourceDrop(
        state: inout State
    ) {
        guard state.hasPendingSourceDrop else {
            return
        }
        var sourceOffset: Int?
        for offset in 0..<state.pendingCount {
            let index = wrappedIndex(
                start: state.pendingHead,
                offset: offset,
                count: state.pendingSlots.count
            )
            if case .sourceDrop? = state.pendingSlots[index] {
                sourceOffset = offset
                break
            }
        }
        guard let sourceOffset else {
            preconditionFailure("Pending source-drop state is inconsistent")
        }

        if sourceOffset < state.pendingCount - 1 {
            for offset in sourceOffset..<(state.pendingCount - 1) {
                let destination = wrappedIndex(
                    start: state.pendingHead,
                    offset: offset,
                    count: state.pendingSlots.count
                )
                let source = wrappedIndex(
                    start: state.pendingHead,
                    offset: offset + 1,
                    count: state.pendingSlots.count
                )
                state.pendingSlots[destination] =
                    state.pendingSlots[source]
            }
        }
        let finalIndex = wrappedIndex(
            start: state.pendingHead,
            offset: state.pendingCount - 1,
            count: state.pendingSlots.count
        )
        state.pendingSlots[finalIndex] = nil
        state.pendingCount -= 1
        state.hasPendingSourceDrop = false
    }

    private static func wrappedIndex(
        start: Int,
        offset: Int,
        count: Int
    ) -> Int {
        precondition(count > 0)
        let distanceToEnd = count - start
        return offset < distanceToEnd
            ? start + offset
            : offset - distanceToEnd
    }

    private static func recordDrop(
        _ reason: AVCaptureVideoDataOutputDropReason,
        state: inout State
    ) {
        if state.droppedSampleCount < UInt64.max {
            state.droppedSampleCount += 1
        }
        state.lastDropReason = reason
    }
}
