import Foundation

/// Subsequence fuzzy matcher for the Quick Open panel. Scores favor
/// consecutive runs, word/`boundary` starts, and shorter candidates —
/// the standard editor-quick-open feel without a dependency.
enum MoltenFuzzyMatch {
    /// nil = no match; higher scores sort first.
    static func score(query: String, candidate: String) -> Int? {
        if query.isEmpty { return 0 }
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        guard q.count <= c.count else { return nil }

        var score = 0
        var qi = 0
        var previousMatched = false
        for (index, ch) in c.enumerated() {
            guard qi < q.count, ch == q[qi] else {
                previousMatched = false
                continue
            }
            qi += 1
            score += 1
            if previousMatched { score += 4 }          // consecutive run
            if index == 0 { score += 6 }               // very first character
            else {
                let prev = c[index - 1]
                if prev == " " || prev == "-" || prev == "_" || prev == "." || prev == "/" {
                    score += 5                          // word boundary
                }
            }
            previousMatched = true
        }
        guard qi == q.count else { return nil }
        // Prefer tighter candidates: same hits in a shorter name rank higher.
        return score * 100 - c.count
    }
}
