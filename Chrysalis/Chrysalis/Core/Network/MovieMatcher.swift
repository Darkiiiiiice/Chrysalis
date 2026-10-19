import Foundation

/// 匹配候选（设计文档 §7.5：只取前 5 个，评分考虑标题精确度、年份、原始标题、热度）。
struct MovieCandidate: Sendable, Equatable, Identifiable {
    var summary: TMDBMovieSummary
    var score: Int

    var id: Int { summary.id }
}

/// 候选评分（纯函数）。
enum MovieMatcher {
    static let maxCandidates = 5

    static func rank(_ results: [TMDBMovieSummary], parsed: ParsedTitle) -> [MovieCandidate] {
        results
            .map { MovieCandidate(summary: $0, score: score($0, parsed: parsed)) }
            .sorted { left, right in
                if left.score != right.score { return left.score > right.score }
                return (left.summary.popularity ?? 0) > (right.summary.popularity ?? 0)
            }
            .prefix(maxCandidates)
            .map { $0 }
    }

    static func score(_ summary: TMDBMovieSummary, parsed: ParsedTitle) -> Int {
        let query = normalize(parsed.primaryTitle)
        var score = 0
        for (candidate, weight) in [(summary.title, 100), (summary.originalTitle, 90)] {
            guard let candidate, !candidate.isEmpty else { continue }
            let normalized = normalize(candidate)
            if normalized == query {
                score = max(score, weight)
            } else if normalized.contains(query), !query.isEmpty {
                score = max(score, weight - 35)
            } else if query.contains(normalized), !normalized.isEmpty {
                score = max(score, weight - 35)
            } else {
                score = max(score, Int(Double(weight) * 0.6 * tokenOverlap(query, normalized)))
            }
        }
        if let year = parsed.year, let candidateYear = summary.year {
            if candidateYear == year {
                score += 30
            } else if abs(candidateYear - year) == 1 {
                score += 10
            }
        }
        // 热度微调（0–10），仅用于同分排序
        score += min(Int((summary.popularity ?? 0) / 20), 10)
        return score
    }

    // MARK: - 文本归一

    static func normalize(_ string: String) -> String {
        let folded = string
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .lowercased()
        var output = ""
        for character in folded {
            if character.isLetter || character.isNumber {
                output.append(character)
            } else if character.isWhitespace {
                output.append(" ")
            }
        }
        return output.split(separator: " ").joined(separator: " ")
    }

    private static func tokenOverlap(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(lhs.split(separator: " ").map(String.init))
        let right = Set(rhs.split(separator: " ").map(String.init))
        guard !left.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.count)
    }
}
