import Foundation

final class CLIPTokenizer {
    static let contextLength = 77
    static let startOfText: Int32 = 49406
    static let endOfText: Int32 = 49407

    private let byteEncoder: [UInt8: Character]
    private let encoder: [String: Int32]
    private let ranks: [Pair: Int]
    private let pattern: NSRegularExpression
    private var cache: [String: [String]] = ["<|startoftext|>": ["<|startoftext|>"], "<|endoftext|>": ["<|endoftext|>"]]

    struct Pair: Hashable {
        let left: String
        let right: String
    }

    init?(mergesPath: String) {
        guard let raw = try? String(contentsOfFile: mergesPath, encoding: .utf8) else {
            Log.semantic.error("merges unreadable path=\(mergesPath, privacy: .public)")
            return nil
        }

        var bytes: [UInt8] = []
        for value in UInt8(ascii: "!")...UInt8(ascii: "~") { bytes.append(value) }
        for value in UInt8(0xA1)...UInt8(0xAC) { bytes.append(value) }
        for value in UInt8(0xAE)...UInt8(0xFF) { bytes.append(value) }
        var scalars = bytes.map { Int($0) }
        var extra = 0
        let present = Set(bytes)
        for value in 0...255 where !present.contains(UInt8(value)) {
            bytes.append(UInt8(value))
            scalars.append(256 + extra)
            extra += 1
        }
        var encoderMap: [UInt8: Character] = [:]
        var alphabet: [String] = []
        alphabet.reserveCapacity(bytes.count)
        for (index, value) in bytes.enumerated() {
            let character = Character(UnicodeScalar(scalars[index])!)
            encoderMap[value] = character
            alphabet.append(String(character))
        }
        byteEncoder = encoderMap

        var vocabulary: [String] = []
        vocabulary.reserveCapacity(49_408)
        vocabulary.append(contentsOf: alphabet)
        vocabulary.append(contentsOf: alphabet.map { $0 + "</w>" })

        var rankMap: [Pair: Int] = [:]
        rankMap.reserveCapacity(48_894)
        var rank = 0
        raw.enumerateLines { line, _ in
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { return }
            let pair = Pair(left: String(parts[0]), right: String(parts[1]))
            rankMap[pair] = rank
            vocabulary.append(pair.left + pair.right)
            rank += 1
        }
        ranks = rankMap
        vocabulary.append("<|startoftext|>")
        vocabulary.append("<|endoftext|>")

        var indexMap: [String: Int32] = [:]
        indexMap.reserveCapacity(vocabulary.count)
        for (index, token) in vocabulary.enumerated() { indexMap[token] = Int32(index) }
        encoder = indexMap

        let source = "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d|\\p{L}+|\\p{N}|[^\\s\\p{L}\\p{N}]+"
        guard let expression = try? NSRegularExpression(pattern: source, options: [.caseInsensitive]) else {
            Log.semantic.error("regex compile failed")
            return nil
        }
        pattern = expression
        Log.semantic.info("tokenizer ready vocab=\(vocabulary.count, privacy: .public) merges=\(rankMap.count, privacy: .public)")
    }

    private func bpe(_ token: String) -> [String] {
        if let cached = cache[token] { return cached }
        var word = token.map { String($0) }
        guard !word.isEmpty else { return [] }
        word[word.count - 1] += "</w>"

        while word.count > 1 {
            var bestRank = Int.max
            var bestIndex = -1
            for index in 0..<(word.count - 1) {
                guard let candidate = ranks[Pair(left: word[index], right: word[index + 1])] else { continue }
                if candidate < bestRank {
                    bestRank = candidate
                    bestIndex = index
                }
            }
            guard bestIndex >= 0 else { break }
            let left = word[bestIndex]
            let right = word[bestIndex + 1]
            var merged: [String] = []
            merged.reserveCapacity(word.count)
            var index = 0
            while index < word.count {
                if index < word.count - 1 && word[index] == left && word[index + 1] == right {
                    merged.append(left + right)
                    index += 2
                } else {
                    merged.append(word[index])
                    index += 1
                }
            }
            word = merged
        }
        cache[token] = word
        return word
    }

    func encode(_ text: String) -> [Int32] {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        let range = NSRange(collapsed.startIndex..<collapsed.endIndex, in: collapsed)
        var ids: [Int32] = []
        pattern.enumerateMatches(in: collapsed, options: [], range: range) { match, _, _ in
            guard let match = match, let piece = Range(match.range, in: collapsed) else { return }
            var mapped = ""
            for byte in Array(collapsed[piece].utf8) {
                guard let character = byteEncoder[byte] else { continue }
                mapped.append(character)
            }
            for fragment in bpe(mapped) {
                guard let id = encoder[fragment] else { continue }
                ids.append(id)
            }
        }
        return ids
    }

    func tokenize(_ text: String) -> [Int32] {
        var ids: [Int32] = [CLIPTokenizer.startOfText]
        ids.append(contentsOf: encode(text))
        ids.append(CLIPTokenizer.endOfText)
        if ids.count > CLIPTokenizer.contextLength {
            ids = Array(ids.prefix(CLIPTokenizer.contextLength))
            ids[CLIPTokenizer.contextLength - 1] = CLIPTokenizer.endOfText
        }
        ids.append(contentsOf: [Int32](repeating: 0, count: CLIPTokenizer.contextLength - ids.count))
        return ids
    }
}
