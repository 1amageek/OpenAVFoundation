public enum AVAuthorizationStatus: Int, Sendable, Hashable {
    case notDetermined = 0
    case restricted = 1
    case denied = 2
    case authorized = 3

    init(_ status: CaptureAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .restricted:
            self = .restricted
        case .denied:
            self = .denied
        case .authorized:
            self = .authorized
        }
    }
}
