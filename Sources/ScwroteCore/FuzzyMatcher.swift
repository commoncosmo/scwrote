import Foundation

/// A successful fuzzy match of a name against a path.
public struct FuzzyMatch: Equatable, Sendable {
    public let score: Int
    /// The matched characters as UTF-16 offsets into the path, sorted and
    /// merged where adjacent, so AppKit can draw them as `NSRange`s.
    public let ranges: [Range<Int>]
}

/// Ranks file paths against what the user typed in quick open.
///
/// The name splits on spaces into terms (empty ones dropped). Every term must
/// match the path as a case- and diacritic-insensitive subsequence, in order
/// within the term; terms may match in any order. The score is the sum of the
/// terms' scores, the ranges the union of theirs. No terms matches with
/// score 0.
///
/// Each term takes the placement of its characters with the best score:
///
/// | Rule | Score |
/// |---|---|
/// | each matched character | +16 |
/// | matched character inside the file name (after the last `/`), not its extension (after the last `.`) | +12 |
/// | at a word start: path start, after `/ _ - . +` or space, or a lowercase to uppercase step | +14 |
/// | continues the previous matched character (a run) | +8 |
/// | typed case equals the path's case on an uppercase path character | +2 |
/// | opening a gap between matched characters | -5 |
/// | each further skipped character in a gap | -1 |
///
/// Characters before the first match cost nothing. Callers break score ties
/// by shorter path, then alphabetically.
public enum FuzzyMatcher {
    private static let matched = 16
    private static let inFileName = 12
    private static let wordStart = 14
    private static let run = 8
    private static let exactCase = 2
    private static let gapOpen = 5
    private static let gapStep = 1

    public static func match(_ name: String, in path: String) -> FuzzyMatch? {
        let terms = name.split(separator: " ")
        if terms.isEmpty { return FuzzyMatch(score: 0, ranges: []) }

        let chars = Array(path)
        let folded = chars.map(fold)
        var offsets: [Int] = []
        offsets.reserveCapacity(chars.count + 1)
        var offset = 0
        for c in chars {
            offsets.append(offset)
            offset += c.utf16.count
        }
        offsets.append(offset)
        let nameStart = (chars.lastIndex(of: "/") ?? -1) + 1
        // Where the extension's dot is; a leading dot (".github") is part of the name.
        var nameEnd = chars.count
        if let dot = chars.lastIndex(of: "."), dot > nameStart { nameEnd = dot }

        var total = 0
        var picked: [Int] = []
        for term in terms {
            guard let (score, indices) = place(Array(term), in: chars, folded: folded, nameRange: nameStart..<nameEnd)
            else { return nil }
            total += score
            picked += indices
        }

        var ranges: [Range<Int>] = []
        for i in Set(picked).sorted() {
            let range = offsets[i]..<offsets[i + 1]
            if let last = ranges.last, last.upperBound == range.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
            } else {
                ranges.append(range)
            }
        }
        return FuzzyMatch(score: total, ranges: ranges)
    }

    private static func fold(_ c: Character) -> String {
        String(c).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The best-scoring placement of `term` in the path, as its score and the
    /// matched character indices; nil when it is not a subsequence.
    private static func place(
        _ term: [Character], in chars: [Character], folded: [String], nameRange: Range<Int>
    ) -> (Int, [Int])? {
        let wanted = term.map(fold)
        // Cheap in-order check before the table.
        var next = 0
        for f in folded where next < wanted.count && f == wanted[next] { next += 1 }
        if next < wanted.count { return nil }

        let n = chars.count, m = term.count
        let none = Int.min
        // score[i][j]: best score with term[i] matched at path[j]; from[i][j]: where term[i-1] was.
        var score = Array(repeating: Array(repeating: none, count: n), count: m)
        var from = Array(repeating: Array(repeating: -1, count: n), count: m)

        for i in 0..<m {
            // Best over k < j - 1 of score[i-1][k] + k, for the gap transition.
            var gapBest = none, gapAt = -1
            for j in 0..<n {
                if i > 0, j >= 2, score[i - 1][j - 2] != none, score[i - 1][j - 2] + (j - 2) > gapBest {
                    gapBest = score[i - 1][j - 2] + (j - 2)
                    gapAt = j - 2
                }
                guard folded[j] == wanted[i] else { continue }
                var here = matched
                if nameRange.contains(j) { here += inFileName }
                if isWordStart(chars, j) { here += wordStart }
                if chars[j].isUppercase && chars[j] == term[i] { here += exactCase }

                if i == 0 {
                    score[i][j] = here
                    continue
                }
                var best = none, origin = -1
                if j >= 1, score[i - 1][j - 1] != none {
                    best = score[i - 1][j - 1] + run
                    origin = j - 1
                }
                if gapAt >= 0 {
                    // Skipped characters: j - k - 1, the first costing gapOpen.
                    let viaGap = gapBest - j + 1 - gapOpen
                    if viaGap > best { best = viaGap; origin = gapAt }
                }
                if best != none {
                    score[i][j] = best + here
                    from[i][j] = origin
                }
            }
        }

        var end = -1
        for j in 0..<n where score[m - 1][j] != none && (end < 0 || score[m - 1][j] > score[m - 1][end]) {
            end = j
        }
        guard end >= 0 else { return nil }
        let best = score[m - 1][end]
        var indices = [end]
        var j = end
        for i in stride(from: m - 1, to: 0, by: -1) {
            j = from[i][j]
            indices.append(j)
        }
        return (best, indices.reversed())
    }

    private static func isWordStart(_ chars: [Character], _ j: Int) -> Bool {
        if j == 0 { return true }
        let before = chars[j - 1]
        if "/_-.+ ".contains(before) { return true }
        return before.isLowercase && chars[j].isUppercase
    }
}
