import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

protocol BriefBuilding: Sendable {
    func build(transcript: String, summary: String?) async throws -> MeetingBrief
}

enum BriefBuilderError: Error, LocalizedError {
    case unavailable(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .unavailable(let s): return s
        case .empty: return "Could not build a meeting brief"
        }
    }
}

struct BriefBuilder: BriefBuilding {
    var forceHeuristic: Bool = false

    func build(transcript: String, summary: String?) async throws -> MeetingBrief {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BriefBuilderError.empty }
        let source = [trimmed, summary ?? ""].joined(separator: "\n")

        var raw: MeetingBrief?
        if !forceHeuristic {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                raw = await buildWithFoundationModels(transcript: trimmed, summary: summary)
            }
            #endif
        }
        let brief = raw ?? heuristicBrief(transcript: trimmed, summary: summary)
        return BriefGrounding.sanitize(brief, against: source)
    }

    private func heuristicBrief(transcript: String, summary: String?) -> MeetingBrief {
        let summaryText = (summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let titleSource = summaryText.isEmpty ? transcript : summaryText
        let title = Self.makeTitle(from: titleSource)
        let subtitle = summaryText.isEmpty
            ? String(transcript.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines)
            : String(summaryText.prefix(220))
        let actions = Self.extractActionHints(from: summaryText.isEmpty ? transcript : summaryText)
        let topics = Self.heuristicTopics(from: summaryText.isEmpty ? transcript : summaryText)
        return MeetingBrief(
            kind: "Meeting notes",
            title: title,
            subtitle: subtitle,
            decisions: [],
            topics: topics,
            actionItems: actions
        )
    }

    /// Split a long summary/transcript into multiple topic cards by paragraph when FM is unavailable.
    static func heuristicTopics(from text: String) -> [MeetingTopic] {
        let blocks = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 40 }
        let source = blocks.isEmpty
            ? text.components(separatedBy: ". ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count > 40 }
            : blocks
        guard !source.isEmpty else {
            let snippet = String(text.prefix(400))
            return [
                MeetingTopic(
                    name: "Discussion",
                    tag: "Overview",
                    summary: snippet,
                    points: [MeetingTopicPoint(title: "Highlights", detail: snippet)]
                ),
            ]
        }
        return Array(source.prefix(8).enumerated()).map { idx, block in
            MeetingTopic(
                name: makeTitle(from: block),
                tag: "Topic \(idx + 1)",
                summary: String(block.prefix(420)),
                points: [
                    MeetingTopicPoint(title: "Detail", detail: String(block.prefix(500))),
                ]
            )
        }
    }

    static func makeTitle(from text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = cleaned.split(separator: " ").prefix(8)
        var title = words.joined(separator: " ")
        if title.count > 60 {
            title = String(title.prefix(57)) + "…"
        }
        if title.isEmpty { return "Meeting notes" }
        return title
    }

    static func extractActionHints(from text: String) -> [MeetingActionItem] {
        let lines = text.components(separatedBy: .newlines)
        var items: [MeetingActionItem] = []
        // Require an explicit action marker — "owner" alone is too loose and invents noise.
        let markers = ["todo:", "to-do:", "action:", "action item", "next step", "follow up:", "follow-up:"]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            guard markers.contains(where: { lower.contains($0) }) else { continue }
            if trimmed.count > 12 {
                items.append(MeetingActionItem(task: trimmed, owner: nil, ownerRole: nil))
            }
            if items.count >= 6 { break }
        }
        return items
    }

    static func sanitizeFileComponent(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let replaced = text
            .replacingOccurrences(of: " ", with: "_")
            .unicodeScalars
            .map { allowed.contains($0) ? Character($0) : Character("-") }
        var out = String(replaced)
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        if out.isEmpty { out = "Meeting" }
        return String(out.prefix(48))
    }

    static func posterFileName(sessionId: UInt32, title: String) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(sessionId))
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyyMMdd_HHmm"
        return "\(df.string(from: date))_\(sanitizeFileComponent(title)).png"
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func buildWithFoundationModels(transcript: String, summary: String?) async -> MeetingBrief? {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }

        let summaryText = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Long meetings: extract partial briefs per chunk, then synthesize with the deep summary.
        // Use the same conservative chunk size as Summarizer to avoid context-window failures.
        if TranscriptChunker.needsChunking(transcript) {
            if let merged = await buildChunkedBrief(transcript: transcript, summary: summaryText) {
                return merged
            }
        }

        let corpus = summaryText.isEmpty ? transcript : (summaryText + "\n\n" + transcript)
        let body = Self.fitForPrompt(corpus, limit: 9_000)
        return await extractBriefOnce(
            body: body,
            preferTopicCount: TranscriptChunker.needsChunking(transcript) ? "4-8" : "2-5"
        )
    }

    @available(iOS 26.0, *)
    private func buildChunkedBrief(transcript: String, summary: String) async -> MeetingBrief? {
        let parts = TranscriptChunker.chunks(transcript)
        var partials: [MeetingBrief] = []
        partials.reserveCapacity(parts.count)

        for (idx, part) in parts.enumerated() {
            if let brief = await extractBriefOnce(
                body: part,
                preferTopicCount: "2-4",
                heading: "Meeting section \(idx + 1) of \(parts.count)"
            ) {
                partials.append(brief)
            }
        }
        guard !partials.isEmpty else { return nil }

        let mergedSeed = Self.mergePartials(partials, fallbackSummary: summary)
        // Final pass: refine title/subtitle/topics using deep summary + merged extractions.
        let catalog = Self.catalog(for: mergedSeed)
        let refineInput = """
            Full meeting summary:
            \(summary.isEmpty ? "(none)" : summary)

            Extracted catalog from transcript sections:
            \(catalog)
            """
        if let refined = await extractBriefOnce(
            body: Self.fitForPrompt(refineInput, limit: 9_500),
            preferTopicCount: "4-8",
            heading: "Build the final poster brief for the whole meeting"
        ) {
            // Preserve grounded actions/decisions collected across chunks even if refine drops some.
            return Self.unionFacts(primary: refined, extras: partials)
        }
        return mergedSeed
    }

    @available(iOS 26.0, *)
    private func extractBriefOnce(
        body: String,
        preferTopicCount: String,
        heading: String? = nil
    ) async -> MeetingBrief? {
        let instructions = """
            Extract a meeting poster brief. ONLY use facts stated in the input.
            Never invent people, roles, todos, follow-ups, metrics, or decisions.
            If something is not explicitly present, leave that field empty.

            kind: short meeting-type label from context, or "Meeting notes".
            title: specific title from content, max 10 words.
            subtitle: one sentence covering who met and major themes when stated; else empty.
            topics: \(preferTopicCount) thematic modules for a multi-topic meeting poster.
            Each topic needs a concrete name, short tag, 2-4 sentence summary with specifics
            (numbers, names, dates when present), and 1-3 detail points.
            Only add highlight metrics that appear verbatim.
            decisions: only decisions clearly agreed — empty array if none.
            actionItems: ONLY explicit todos / next steps / follow-ups stated in the text.
            Leave actionItems empty if none were stated. Never invent owners.
            owner/ownerRole only when that person is named for that task.
            Do not use placeholder names (John Doe, Someone, Unassigned, TBD).
            """

        let promptBody = heading.map { "\($0)\n\n\(body)" } ?? body

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: promptBody,
                generating: MeetingBriefDraft.self
            )
            return response.content.asBrief()
        } catch {
            // Fall through to JSON.
        }

        do {
            let session = LanguageModelSession(instructions: """
                Return compact JSON for a meeting poster with keys:
                kind, title, subtitle, decisions (string[]),
                topics ([{name, tag, summary, points:[{title, detail}], highlight, highlightLabel}]),
                actionItems ([{task, owner, ownerRole}]).
                Prefer \(preferTopicCount) detailed topics for long meetings.
                RULES: Extract only what is explicitly in the input. Never invent.
                If there are no todos/follow-ups, actionItems must be [].
                If an owner is not named in the text, set owner/ownerRole to null.
                Never use placeholder names (John Doe, Someone, Unassigned, TBD).
                highlight only if the number appears in the text; else null.
                No markdown fences.
                """)
            let response = try await session.respond(to: promptBody)
            return Self.parseJSONBrief(response.content)
        } catch {
            return nil
        }
    }

    static func fitForPrompt(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        // Prefer the start + end so opening context and closing actions both survive.
        let head = limit * 2 / 3
        let tail = limit - head - 20
        return String(text.prefix(head)) + "\n…\n" + String(text.suffix(max(0, tail)))
    }

    static func mergePartials(_ partials: [MeetingBrief], fallbackSummary: String) -> MeetingBrief {
        let title = partials.first(where: { !$0.title.isEmpty && $0.title != "Meeting notes" })?.title
            ?? Self.makeTitle(from: fallbackSummary.isEmpty ? (partials.first?.subtitle ?? "Meeting notes") : fallbackSummary)
        let kind = partials.first(where: { !$0.kind.isEmpty })?.kind ?? "Meeting notes"
        let subtitle = partials.first(where: { !$0.subtitle.isEmpty })?.subtitle
            ?? String(fallbackSummary.prefix(220))
        var topics: [MeetingTopic] = []
        var seenTopic = Set<String>()
        for brief in partials {
            for topic in brief.topics {
                let key = topic.name.lowercased()
                if seenTopic.contains(key) { continue }
                seenTopic.insert(key)
                topics.append(topic)
                if topics.count >= 8 { break }
            }
            if topics.count >= 8 { break }
        }
        if topics.isEmpty, !fallbackSummary.isEmpty {
            topics = heuristicTopics(from: fallbackSummary)
        }
        return MeetingBrief(
            kind: kind,
            title: title,
            subtitle: subtitle,
            decisions: uniqueStrings(partials.flatMap(\.decisions)),
            topics: topics,
            actionItems: uniqueActions(partials.flatMap(\.actionItems))
        )
    }

    static func unionFacts(primary: MeetingBrief, extras: [MeetingBrief]) -> MeetingBrief {
        var topics = primary.topics
        var seen = Set(topics.map { $0.name.lowercased() })
        for brief in extras {
            for topic in brief.topics where !seen.contains(topic.name.lowercased()) {
                topics.append(topic)
                seen.insert(topic.name.lowercased())
                if topics.count >= 8 { break }
            }
            if topics.count >= 8 { break }
        }
        return MeetingBrief(
            kind: primary.kind,
            title: primary.title,
            subtitle: primary.subtitle,
            decisions: uniqueStrings(primary.decisions + extras.flatMap(\.decisions)),
            topics: topics,
            actionItems: uniqueActions(primary.actionItems + extras.flatMap(\.actionItems))
        )
    }

    static func catalog(for brief: MeetingBrief) -> String {
        var lines: [String] = []
        lines.append("Title candidates: \(brief.title)")
        if !brief.decisions.isEmpty {
            lines.append("Decisions:")
            lines.append(contentsOf: brief.decisions.map { "- \($0)" })
        }
        lines.append("Topics:")
        for topic in brief.topics {
            lines.append("- \(topic.name) [\(topic.tag)]: \(topic.summary)")
            for point in topic.points {
                lines.append("  • \(point.title): \(point.detail)")
            }
        }
        if !brief.actionItems.isEmpty {
            lines.append("Actions:")
            for item in brief.actionItems {
                let owner = item.owner.map { " (\($0))" } ?? ""
                lines.append("- \(item.task)\(owner)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func uniqueStrings(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in items {
            let key = item.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(item)
        }
        return out
    }

    private static func uniqueActions(_ items: [MeetingActionItem]) -> [MeetingActionItem] {
        var seen = Set<String>()
        var out: [MeetingActionItem] = []
        for item in items {
            let key = item.task.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(item)
        }
        return out
    }

    @available(iOS 26.0, *)
    private static func parseJSONBrief(_ raw: String) -> MeetingBrief? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8),
              let draft = try? JSONDecoder().decode(MeetingBriefDraftJSON.self, from: data) else {
            return nil
        }
        return draft.asBrief()
    }
    #endif
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct MeetingBriefDraft {
    @Guide(description: "Short meeting-type pill label")
    var kind: String
    @Guide(description: "Specific meeting title, max 10 words")
    var title: String
    @Guide(description: "One sentence: who met and what was covered")
    var subtitle: String
    @Guide(description: "Decisions explicitly agreed in the transcript; empty if none")
    var decisions: [String]
    @Guide(description: "Detailed topic modules for the poster; cover distinct themes; never invent")
    var topics: [MeetingTopicDraft]
    @Guide(description: "Only explicit todos/follow-ups from the transcript; empty if none; never invent owners")
    var actionItems: [MeetingActionDraft]

    func asBrief() -> MeetingBrief {
        MeetingBrief(
            kind: kind.trimmedNonEmpty ?? "Meeting notes",
            title: title.trimmedNonEmpty ?? "Meeting notes",
            subtitle: subtitle.trimmingCharacters(in: .whitespacesAndNewlines),
            decisions: decisions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            topics: topics.compactMap { $0.asTopic() },
            actionItems: actionItems.compactMap { $0.asItem() }
        )
    }
}

@available(iOS 26.0, *)
@Generable
struct MeetingTopicDraft {
    var name: String
    var tag: String
    var summary: String
    var points: [MeetingPointDraft]
    var highlight: String
    var highlightLabel: String

    func asTopic() -> MeetingTopic? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        let hi = highlight.trimmingCharacters(in: .whitespacesAndNewlines)
        let hl = highlightLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingTopic(
            name: n,
            tag: tag.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            points: points.compactMap { $0.asPoint() },
            highlight: hi.isEmpty ? nil : hi,
            highlightLabel: hl.isEmpty ? nil : hl
        )
    }
}

@available(iOS 26.0, *)
@Generable
struct MeetingPointDraft {
    var title: String
    var detail: String

    func asPoint() -> MeetingTopicPoint? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !d.isEmpty else { return nil }
        return MeetingTopicPoint(
            title: t.isEmpty ? "Detail" : t,
            detail: d
        )
    }
}

@available(iOS 26.0, *)
@Generable
struct MeetingActionDraft {
    var task: String
    var owner: String
    var ownerRole: String

    func asItem() -> MeetingActionItem? {
        let t = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let o = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = ownerRole.trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingActionItem(
            task: t,
            owner: o.isEmpty ? nil : o,
            ownerRole: r.isEmpty ? nil : r
        )
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
#endif

struct MeetingBriefDraftJSON: Codable {
    var kind: String?
    var title: String
    var subtitle: String?
    var decisions: [String]?
    var topics: [TopicJSON]?
    var actionItems: [ActionJSON]?

    struct TopicJSON: Codable {
        var name: String
        var tag: String?
        var summary: String?
        var points: [PointJSON]?
        var highlight: String?
        var highlightLabel: String?
    }

    struct PointJSON: Codable {
        var title: String
        var detail: String?
    }

    struct ActionJSON: Codable {
        var task: String
        var owner: String?
        var ownerRole: String?
    }

    func asBrief() -> MeetingBrief {
        MeetingBrief(
            kind: (kind?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Meeting notes",
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Meeting notes" : title,
            subtitle: subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            decisions: (decisions ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            topics: (topics ?? []).compactMap { t in
                let name = t.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                return MeetingTopic(
                    name: name,
                    tag: t.tag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    summary: t.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    points: (t.points ?? []).compactMap { p in
                        let title = p.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !title.isEmpty else { return nil }
                        return MeetingTopicPoint(
                            title: title,
                            detail: p.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        )
                    },
                    highlight: t.highlight?.trimmingCharacters(in: .whitespacesAndNewlines),
                    highlightLabel: t.highlightLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            },
            actionItems: (actionItems ?? []).compactMap { a in
                let task = a.task.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !task.isEmpty else { return nil }
                let owner = a.owner?.trimmingCharacters(in: .whitespacesAndNewlines)
                let role = a.ownerRole?.trimmingCharacters(in: .whitespacesAndNewlines)
                return MeetingActionItem(
                    task: task,
                    owner: (owner?.isEmpty == false) ? owner : nil,
                    ownerRole: (role?.isEmpty == false) ? role : nil
                )
            }
        )
    }
}
