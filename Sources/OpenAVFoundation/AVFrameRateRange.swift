public final class AVFrameRateRange: Hashable, Sendable {
    public let minFrameRate: Double
    public let maxFrameRate: Double

    init(
        minimum: Double,
        maximum: Double
    ) {
        minFrameRate = minimum
        maxFrameRate = maximum
    }

    public static func == (
        lhs: AVFrameRateRange,
        rhs: AVFrameRateRange
    ) -> Bool {
        lhs.minFrameRate == rhs.minFrameRate
            && lhs.maxFrameRate == rhs.maxFrameRate
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(minFrameRate)
        hasher.combine(maxFrameRate)
    }
}
