import Foundation

enum TranscriptChunker {
    /// Soft per-prompt budget for on-device Foundation Models (~4k token window with instructions + output).
    /// Keep this conservative — oversized chunks were causing context-window failures → summary skipped.
    static let defaultMaxChars = 2_800
    static let defaultOverlap = 180

    static func needsChunking(_ text: String, maxChars: Int = defaultMaxChars) -> Bool {
        text.count > maxChars
    }

    /// Split on paragraph/sentence boundaries with overlap so long meetings are fully covered.
    static func chunks(
        _ text: String,
        maxChars: Int = defaultMaxChars,
        overlap: Int = defaultOverlap
    ) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > maxChars else { return [trimmed] }

        var result: [String] = []
        var start = trimmed.startIndex

        while start < trimmed.endIndex {
            let remaining = trimmed.distance(from: start, to: trimmed.endIndex)
            if remaining <= maxChars {
                let piece = String(trimmed[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { result.append(piece) }
                break
            }

            let roughEnd = trimmed.index(start, offsetBy: maxChars)
            let window = trimmed[start..<roughEnd]
            let breakAt = preferredBreak(in: window) ?? roughEnd
            let piece = String(trimmed[start..<breakAt]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append(piece) }

            // Overlap: step back a little so topics spanning a boundary aren't lost.
            let overlapStart = trimmed.index(breakAt, offsetBy: -min(overlap, trimmed.distance(from: start, to: breakAt)), limitedBy: start) ?? breakAt
            let next = overlapStart > start ? overlapStart : breakAt
            if next <= start {
                // Safety: always advance.
                start = breakAt < trimmed.endIndex ? trimmed.index(after: breakAt) : trimmed.endIndex
            } else {
                start = next
            }
        }

        return result
    }

    private static func preferredBreak(in window: Substring) -> String.Index? {
        // Prefer paragraph, then sentence, then whitespace — near the end of the window.
        let minKeep = window.index(window.startIndex, offsetBy: max(0, window.count * 2 / 3), limitedBy: window.endIndex) ?? window.startIndex
        let search = window[minKeep..<window.endIndex]

        if let para = search.range(of: "\n\n", options: .backwards)?.lowerBound {
            return para
        }
        for sep in [". ", "? ", "! ", ".\n", "?\n", "!\n"] {
            if let r = search.range(of: sep, options: .backwards) {
                return r.upperBound
            }
        }
        if let space = search.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards)?.lowerBound {
            return space
        }
        return nil
    }
}
