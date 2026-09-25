import Foundation

/// Compares two renders of a tree keyed by stable element index.
enum TreeDiff {
    enum Outcome: Equatable {
        case unchanged
        /// Too much changed for a diff to be useful; send the full tree.
        case full
        case changes([String])
    }

    /// `order` is the new tree's element order; `lines` its rendered lines by index.
    static func compute(baseline: [Int: String], lines: [Int: String], order: [Int]) -> Outcome {
        var changes: [String] = []
        for index in order {
            guard let text = lines[index] else { continue }
            if let old = baseline[index] {
                if old != text { changes.append("~ " + text) }
            } else {
                changes.append("+ " + text)
            }
        }
        let removed = baseline.keys.filter { lines[$0] == nil }.sorted().compactMap { baseline[$0].map { "- " + $0 } }
        let total = changes.count + removed.count
        if total == 0 { return .unchanged }
        if total * 2 > max(lines.count, 1) { return .full }
        return .changes(changes + removed)
    }
}
