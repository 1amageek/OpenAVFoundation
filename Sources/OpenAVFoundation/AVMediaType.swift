public struct AVMediaType: RawRepresentable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static let video = AVMediaType(rawValue: "vide")
    public static let audio = AVMediaType(rawValue: "soun")
    public static let metadata = AVMediaType(rawValue: "meta")

    var captureRawValue: String {
        switch self {
        case .video:
            "video"
        case .audio:
            "audio"
        case .metadata:
            "metadata"
        default:
            rawValue
        }
    }
}
