import Synchronization

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

    /// The maximum number of samples queued behind an active delegate call.
    ///
    /// This is a portable bounded-backpressure extension. Apple AVFoundation
    /// does not expose a queue-capacity property.
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
    private struct DeliveryItem: Sendable {
        // Reuse the graph's single audited immutable output-reference boundary.
        // The circular slot owns this reference only until dequeue and callback
        // completion; no media bytes or pointers are copied into the item.
        let output: CaptureOutputReference
        let delegate: any AVCaptureVideoDataOutputSampleBufferDelegate
        let sampleBuffer: any CMSampleBuffer
        let connection: AVCaptureConnection
    }

    private struct State: Sendable {
        var delegate: (any AVCaptureVideoDataOutputSampleBufferDelegate)?
        var discardsLateSamples = true
        var pendingSampleLimit = 1
        var pendingSlots: [DeliveryItem?] = []
        var pendingHead = 0
        var pendingCount = 0
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
        guard limit >= 0 else {
            throw .invalidPendingSampleLimit(limit)
        }
        state.withLock { state in
            state.pendingSampleLimit = limit
        }
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
        var shouldStartDelivery = false
        let disposition = state.withLock { state -> CaptureSampleDisposition in
            guard let delegate = state.delegate else {
                return .dropped
            }

            if state.isDelivering {
                if state.discardsLateSamples {
                    Self.recordDrop(.frameWasLate, state: &state)
                    return .dropped
                }
                guard state.pendingCount < state.pendingSampleLimit else {
                    Self.recordDrop(.queueFull, state: &state)
                    return .dropped
                }
            }

            guard Self.enqueue(
                DeliveryItem(
                    output: CaptureOutputReference(value: output),
                    delegate: delegate,
                    sampleBuffer: sampleBuffer,
                    connection: connection
                ),
                state: &state
            ) else {
                Self.recordDrop(.queueFull, state: &state)
                return .dropped
            }
            if !state.isDelivering {
                state.isDelivering = true
                shouldStartDelivery = true
            }
            return .accepted
        }

        if shouldStartDelivery {
            drain()
        }
        return disposition
    }

    func notifySourceDrop(
        _ event: CaptureStreamDropEvent,
        output: AVCaptureVideoDataOutput,
        from connection: AVCaptureConnection
    ) {
        let delegate = state.withLock { state in state.delegate }
        delegate?.captureOutput(
            output,
            didDrop: event,
            from: connection
        )
    }

    private func drain() {
        while true {
            let item = state.withLock { state -> DeliveryItem? in
                guard let item = Self.dequeue(state: &state) else {
                    state.isDelivering = false
                    return nil
                }
                return item
            }

            guard let item else {
                return
            }
            item.delegate.captureOutput(
                item.output.value,
                didOutput: item.sampleBuffer,
                from: item.connection
            )
        }
    }

    private static func enqueue(
        _ item: DeliveryItem,
        state: inout State
    ) -> Bool {
        if state.pendingSlots.isEmpty {
            state.pendingSlots = [nil]
        } else if state.pendingCount == state.pendingSlots.count {
            let (requiredCount, requiredOverflow) =
                state.pendingCount.addingReportingOverflow(1)
            guard !requiredOverflow else {
                return false
            }
            let (doubledCount, doubledOverflow) =
                state.pendingSlots.count.multipliedReportingOverflow(by: 2)
            let expandedCount = doubledOverflow
                ? requiredCount
                : max(doubledCount, requiredCount)
            guard expandedCount >= requiredCount else {
                return false
            }
            var expanded = [DeliveryItem?](
                repeating: nil,
                count: expandedCount
            )
            for offset in 0..<state.pendingCount {
                let sourceIndex = wrappedIndex(
                    start: state.pendingHead,
                    offset: offset,
                    count: state.pendingSlots.count
                )
                expanded[offset] = state.pendingSlots[sourceIndex]
                state.pendingSlots[sourceIndex] = nil
            }
            state.pendingSlots = expanded
            state.pendingHead = 0
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
        return item
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
