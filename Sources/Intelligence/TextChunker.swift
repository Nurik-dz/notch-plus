import Foundation

/// Picks the parts of a long text that matter for a question, so a document much longer than the
/// on-device model can read at once can still be asked about. Plain keyword scoring, no model involved.
enum TextChunker {
    /// Cuts text into pieces of about `size` characters at paragraph or sentence ends.
    static func split(_ text: String, size: Int = 900) -> [String] {
        let paragraphs = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var chunks: [String] = []
        var current = ""
        func flush() { if !current.isEmpty { chunks.append(current); current = "" } }
        for p in paragraphs {
            if p.count > size {                                  // a very long line: cut at sentence ends
                flush()
                var piece = ""
                for sentence in p.split(omittingEmptySubsequences: true, whereSeparator: { ".!?؟。".contains($0) }) {
                    if piece.count + sentence.count > size, !piece.isEmpty { chunks.append(piece); piece = "" }
                    piece += (piece.isEmpty ? "" : ". ") + sentence
                    while piece.count > size * 2 { chunks.append(String(piece.prefix(size))); piece = String(piece.dropFirst(size)) }
                }
                if !piece.isEmpty { chunks.append(piece) }
            } else {
                if current.count + p.count + 1 > size { flush() }
                current += (current.isEmpty ? "" : "\n") + p
            }
        }
        flush()
        return chunks
    }

    private static let stop: Set<String> = ["the", "and", "for", "are", "was", "were", "what", "which", "who", "whom", "when", "where",
                                            "how", "does", "did", "this", "that", "these", "those", "with", "from", "have", "has", "had",
                                            "about", "into", "than", "then", "there", "their", "its", "your", "you", "can", "will", "not",
                                            "tell", "give", "show", "please", "any", "all", "whats", "is", "in", "of", "to", "a", "an", "it", "on", "by", "or", "as", "at"]

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init).filter { $0.count > 1 && !stop.contains($0) }
    }

    /// The best chunks for a question, in their original order, within `budget` characters.
    /// The first chunk (title, summary, header) is kept when there is room, because questions are often about "this document".
    static func relevant(_ chunks: [String], to question: String, budget: Int) -> [String] {
        guard !chunks.isEmpty else { return [] }
        if chunks.reduce(0, { $0 + $1.count }) <= budget { return chunks }
        let q = Set(words(question))
        let docWords = chunks.map { Set(words($0)) }
        let n = Double(chunks.count)
        var idf: [String: Double] = [:]
        for w in q { idf[w] = log(1 + n / (1 + Double(docWords.filter { $0.contains(w) }.count))) }
        let scores: [Double] = chunks.enumerated().map { i, c in
            let ws = words(c)
            var s = 0.0
            for w in q {
                let tf = Double(ws.filter { $0 == w || ($0.count > 4 && w.count > 4 && ($0.hasPrefix(w) || w.hasPrefix($0))) }.count)
                s += (1 + log(1 + tf)) * (tf > 0 ? 1 : 0) * (idf[w] ?? 1)
            }
            return i == 0 ? s + 0.01 : s
        }
        var chosen = Set<Int>()
        var used = 0
        if chunks[0].count <= budget / 4 { chosen.insert(0); used += chunks[0].count }       // keep the opening
        for i in scores.indices.sorted(by: { scores[$0] > scores[$1] }) where scores[i] > 0 || chosen.isEmpty {
            if chosen.contains(i) { continue }
            if used + chunks[i].count > budget { continue }
            chosen.insert(i); used += chunks[i].count
        }
        if chosen.isEmpty { chosen.insert(0) }
        return chosen.sorted().map { chunks[$0] }
    }
}
