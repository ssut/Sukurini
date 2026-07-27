import Foundation

enum DateFolderFormat {
    static let defaultPattern = "yyyy-MM-dd"
    static let maximumDepth = 4
    static let maximumComponentBytes = 255

    struct Resolved {
        let pattern: String
        let corrected: Bool
        let depth: Int
        let isDateless: Bool
    }

    enum Invalid: String, Error {
        case empty
        case absolute
        case traversal
        case hiddenComponent
        case illegalCharacter
        case emptyComponent
        case componentTooLong
        case tooDeep
        case unbalancedQuote
        case renderFailed

        var message: String {
            switch self {
            case .empty:
                return L10n.FormatError.empty
            case .absolute:
                return L10n.FormatError.absolute
            case .traversal:
                return L10n.FormatError.traversal
            case .hiddenComponent:
                return L10n.FormatError.hiddenComponent
            case .illegalCharacter:
                return L10n.FormatError.illegalCharacter
            case .emptyComponent:
                return L10n.FormatError.emptyComponent
            case .componentTooLong:
                return L10n.FormatError.componentTooLong
            case .tooDeep:
                return L10n.FormatError.tooDeep(DateFolderFormat.maximumDepth)
            case .unbalancedQuote:
                return L10n.FormatError.unbalancedQuote
            case .renderFailed:
                return L10n.FormatError.renderFailed
            }
        }
    }

    static func resolve(_ raw: String) -> Result<Resolved, Invalid> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard !trimmed.hasPrefix("/") else { return .failure(.absolute) }
        guard !trimmed.hasSuffix("/") else { return .failure(.emptyComponent) }

        let correction = correct(trimmed)
        guard correction.balanced else { return .failure(.unbalancedQuote) }

        var renderings: [String] = []
        for probe in probeDates {
            guard let rendered = render(probe, pattern: correction.pattern) else { return .failure(.renderFailed) }
            if let issue = validate(rendered) { return .failure(issue) }
            renderings.append(rendered)
        }

        let depth = renderings[0].split(separator: "/", omittingEmptySubsequences: false).count
        let dateless = Set(renderings).count == 1
        return .success(
            Resolved(
                pattern: correction.pattern,
                corrected: correction.pattern != trimmed,
                depth: depth,
                isDateless: dateless
            )
        )
    }

    static func relativePath(for date: Date, pattern: String) -> String? {
        render(date, pattern: pattern)
    }

    private static func correct(_ pattern: String) -> (pattern: String, balanced: Bool) {
        var output = ""
        var quoted = false
        for character in pattern {
            if character == "'" {
                quoted.toggle()
                output.append(character)
                continue
            }
            if quoted {
                output.append(character)
                continue
            }
            switch character {
            case "Y":
                output.append("y")
            case "D":
                output.append("d")
            default:
                output.append(character)
            }
        }
        return (output, !quoted)
    }

    private static func validate(_ rendered: String) -> Invalid? {
        guard !rendered.isEmpty else { return .renderFailed }
        guard !rendered.hasPrefix("/") else { return .absolute }
        guard !rendered.contains(":") else { return .illegalCharacter }

        let components = rendered.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= maximumDepth else { return .tooDeep }
        for component in components {
            guard !component.isEmpty else { return .emptyComponent }
            guard component != ".", component != ".." else { return .traversal }
            guard !component.hasPrefix(".") else { return .hiddenComponent }
            guard component.utf8.count <= maximumComponentBytes else { return .componentTooLong }
        }
        return nil
    }

    private static let formatterLock = NSLock()
    private static var cachedFormatter: DateFormatter?
    private static var cachedPattern: String?

    private static func render(_ date: Date, pattern: String) -> String? {
        formatterLock.lock()
        defer { formatterLock.unlock() }

        let formatter: DateFormatter
        if let cached = cachedFormatter, cachedPattern == pattern {
            formatter = cached
        } else {
            let fresh = DateFormatter()
            fresh.locale = Locale(identifier: "en_US_POSIX")
            fresh.calendar = Calendar(identifier: .gregorian)
            fresh.dateFormat = pattern
            cachedFormatter = fresh
            cachedPattern = pattern
            formatter = fresh
        }
        formatter.timeZone = .current

        let rendered = formatter.string(from: date)
        return rendered.isEmpty ? nil : rendered
    }

    private static let probeDates: [Date] = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let early = DateComponents(year: 2001, month: 1, day: 2, hour: 12)
        let late = DateComponents(year: 2027, month: 12, day: 31, hour: 12)
        return [early, late].compactMap { calendar.date(from: $0) }
    }()
}
