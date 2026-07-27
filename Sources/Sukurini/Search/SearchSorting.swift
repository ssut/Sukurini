import Foundation

enum GallerySortOrder: String, CaseIterable {
    case relevance
    case date

    var title: String {
        switch self {
        case .relevance: return L10n.Gallery.sortRelevance
        case .date: return L10n.Gallery.sortDate
        }
    }

    var summary: String {
        switch self {
        case .relevance: return L10n.Gallery.sortRelevanceSummary
        case .date: return L10n.Gallery.sortDateSummary
        }
    }
}

struct SearchOutcome {
    let query: String
    let isRanked: Bool
    let paths: [String]

    static func empty(query: String) -> SearchOutcome {
        SearchOutcome(query: query, isRanked: false, paths: [])
    }
}
