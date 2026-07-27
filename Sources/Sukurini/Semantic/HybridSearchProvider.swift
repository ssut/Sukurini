import Foundation

final class HybridSearchProvider: SearchProviding {
    static let semanticLimit = 120

    private let index: SearchIndex
    private weak var semantic: SemanticCoordinator?

    init(index: SearchIndex, semantic: SemanticCoordinator?) {
        self.index = index
        self.semantic = semantic
    }

    var isReady: Bool { index.isReady }

    var usesSemanticSearch: Bool {
        semantic?.isReady ?? false
    }

    func search(query: String, completion: @escaping (SearchOutcome) -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.empty(query: query))
            return
        }

        guard let semantic, semantic.isReady else {
            index.search(query: query) { requested, paths in
                Log.search.info("search backend=text hits=\(paths.count, privacy: .public)")
                completion(SearchOutcome(query: requested, isRanked: false, paths: Array(paths)))
            }
            return
        }

        semantic.search(query: trimmed, limit: HybridSearchProvider.semanticLimit) { hits in
            Log.search.info("search backend=semantic hits=\(hits.count, privacy: .public)")
            completion(SearchOutcome(query: query, isRanked: true, paths: hits.map { $0.path }))
        }
    }
}
