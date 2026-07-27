import Foundation

enum UpdateChannel: String, CaseIterable {
    case stable
    case preview

    static let previewIdentifier = "preview"

    static func resolved(_ raw: String?) -> UpdateChannel {
        guard let raw, let parsed = UpdateChannel(rawValue: raw) else { return .stable }
        return parsed
    }

    var displayName: String {
        switch self {
        case .stable:
            return L10n.Updates.stableName
        case .preview:
            return L10n.Updates.previewName
        }
    }

    var summary: String {
        switch self {
        case .stable:
            return L10n.Updates.stableSummary
        case .preview:
            return L10n.Updates.previewSummary
        }
    }

    var allowedSparkleChannels: Set<String> {
        switch self {
        case .stable:
            return []
        case .preview:
            return [Self.previewIdentifier]
        }
    }
}
