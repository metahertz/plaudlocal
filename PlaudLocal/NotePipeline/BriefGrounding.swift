import Foundation

enum BriefGrounding {
    /// Names the model commonly invents when it has nothing real to put in an owner field.
    private static let placeholderNames: Set<String> = [
        "john doe", "jane doe", "john", "jane", "doe",
        "someone", "somebody", "anyone", "everybody",
        "tbd", "n/a", "na", "none", "unknown", "unassigned",
        "owner", "assignee", "user", "person", "name", "team member",
        "participant", "speaker", "attendee", "placeholder",
    ]

    private static let placeholderTasks: Set<String> = [
        "follow up", "follow-up", "todo", "to do", "action item",
        "next step", "tbd", "n/a", "none",
    ]

    /// Drop invented actions/owners/decisions that are not grounded in the source text.
    static func sanitize(_ brief: MeetingBrief, against source: String) -> MeetingBrief {
        let corpus = normalized(source)
        let decisions = brief.decisions.compactMap { decision -> String? in
            let d = decision.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !d.isEmpty else { return nil }
            guard isGrounded(d, in: corpus) else { return nil }
            return d
        }

        let actions = brief.actionItems.compactMap { item -> MeetingActionItem? in
            let task = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { return nil }
            if isPlaceholderTask(task) { return nil }
            // Action items must be evidenced in the transcript/summary — do not invent follow-ups.
            guard isGrounded(task, in: corpus) || looksLikeExplicitAction(task, in: corpus) else {
                return nil
            }

            var owner = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines)
            var role = item.ownerRole?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let o = owner {
                if isPlaceholderName(o) || !nameAppears(o, in: corpus) {
                    owner = nil
                    role = nil
                }
            } else {
                role = nil
            }
            if let r = role, isPlaceholderName(r) {
                role = nil
            }

            return MeetingActionItem(task: task, owner: owner, ownerRole: role)
        }

        // Strip empty highlights that look fabricated (number not in source).
        let topics = brief.topics.map { topic -> MeetingTopic in
            var t = topic
            if let hi = t.highlight?.trimmingCharacters(in: .whitespacesAndNewlines), !hi.isEmpty {
                let digits = hi.filter(\.isNumber)
                if !digits.isEmpty, !corpus.contains(digits), !corpus.contains(normalized(hi)) {
                    t.highlight = nil
                    t.highlightLabel = nil
                }
            }
            return t
        }

        return MeetingBrief(
            kind: brief.kind,
            title: brief.title,
            subtitle: brief.subtitle,
            decisions: decisions,
            topics: topics,
            actionItems: actions
        )
    }

    static func isPlaceholderName(_ name: String) -> Bool {
        let n = normalized(name)
        if placeholderNames.contains(n) { return true }
        // "John Doe"-style two-token placeholders.
        let parts = n.split(separator: " ")
        if parts.count == 2,
           placeholderNames.contains(String(parts[0])),
           placeholderNames.contains(String(parts[1])) {
            return true
        }
        return false
    }

    private static func isPlaceholderTask(_ task: String) -> Bool {
        let t = normalized(task)
        if placeholderTasks.contains(t) { return true }
        if t.count < 8 { return true }
        return false
    }

    private static func nameAppears(_ name: String, in corpus: String) -> Bool {
        let n = normalized(name)
        guard n.count >= 2 else { return false }
        // Require the full name, or a distinctive first token (≥3 chars) that appears as a word.
        if corpus.contains(n) { return true }
        let parts = n.split(separator: " ").map(String.init).filter { $0.count >= 3 }
        guard let first = parts.first else { return false }
        return corpus.split(whereSeparator: { !$0.isLetter }).map(String.init).contains(first)
    }

    private static func isGrounded(_ phrase: String, in corpus: String) -> Bool {
        let words = significantWords(phrase)
        guard !words.isEmpty else { return false }
        // Prefer a contiguous chunk of the phrase appearing in source.
        let compact = normalized(phrase)
        if compact.count >= 12, corpus.contains(compact) { return true }
        let hits = words.filter { corpus.contains($0) }.count
        // Majority of content words must appear in the source text.
        return hits * 2 >= words.count && hits >= 2
    }

    private static func looksLikeExplicitAction(_ task: String, in corpus: String) -> Bool {
        let markers = ["will ", "I'll ", "I will ", "let's ", "todo", "to-do", "action", "follow up", "follow-up", "next step", "need to", "needs to", "should "]
        let lowerTask = task.lowercased()
        let hasMarker = markers.contains { lowerTask.contains($0) }
        guard hasMarker else { return false }
        return isGrounded(task, in: corpus) || significantWords(task).filter { corpus.contains($0) }.count >= 1
    }

    private static func significantWords(_ text: String) -> [String] {
        let stop: Set<String> = [
            "the", "a", "an", "and", "or", "to", "of", "in", "on", "for", "with",
            "is", "are", "be", "will", "we", "i", "you", "they", "this", "that",
            "it", "as", "at", "by", "from", "our", "their",
        ]
        return normalized(text)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 && !stop.contains($0) }
    }

    private static func normalized(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
