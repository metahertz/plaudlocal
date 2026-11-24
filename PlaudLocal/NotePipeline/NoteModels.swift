import Foundation

enum PipelineStatus: String, Codable, Equatable {
    case pending
    case running
    case done
    case skipped
    case failed
}

struct NoteMetadata: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var sessionId: UInt32
    var createdAt: Date
    var durationSeconds: Int
    /// Display title: the recording date label, then the brief's title, unless the user set one.
    var title: String
    /// Stable recording date/time label from the session id (never overwritten by brief title).
    var recordingLabel: String
    var transcriptStatus: PipelineStatus
    var summaryStatus: PipelineStatus
    var briefStatus: PipelineStatus
    var exportStatus: PipelineStatus
    var audioFileName: String
    /// Poster image basename inside the note directory, e.g. `20261105_1430_Weekly_Sync.png`.
    var posterFileName: String?
    /// When true, on-device ASR/summary/poster were skipped so raw audio can be processed externally.
    var audioOnlyExport: Bool
    /// The user typed `title`; only `NoteStore.renameNote` changes it (an empty name clears this).
    var titleSetByUser: Bool

    var recordingDate: Date {
        Date(timeIntervalSince1970: TimeInterval(sessionId))
    }

    var libraryHeadline: String {
        titleSetByUser || briefStatus == .done ? title : recordingLabel
    }

    enum CodingKeys: String, CodingKey {
        case id, sessionId, createdAt, durationSeconds, title, recordingLabel
        case transcriptStatus, summaryStatus, briefStatus, exportStatus
        case audioFileName, posterFileName, audioOnlyExport, titleSetByUser
    }

    init(
        id: String,
        sessionId: UInt32,
        createdAt: Date,
        durationSeconds: Int,
        title: String,
        recordingLabel: String? = nil,
        transcriptStatus: PipelineStatus,
        summaryStatus: PipelineStatus,
        briefStatus: PipelineStatus = .pending,
        exportStatus: PipelineStatus,
        audioFileName: String,
        posterFileName: String? = nil,
        audioOnlyExport: Bool = false,
        titleSetByUser: Bool = false
    ) {
        self.id = id
        self.sessionId = sessionId
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.title = title
        self.recordingLabel = recordingLabel ?? title
        self.transcriptStatus = transcriptStatus
        self.summaryStatus = summaryStatus
        self.briefStatus = briefStatus
        self.exportStatus = exportStatus
        self.audioFileName = audioFileName
        self.posterFileName = posterFileName
        self.audioOnlyExport = audioOnlyExport
        self.titleSetByUser = titleSetByUser
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionId = try c.decode(UInt32.self, forKey: .sessionId)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        durationSeconds = try c.decode(Int.self, forKey: .durationSeconds)
        title = try c.decode(String.self, forKey: .title)
        recordingLabel = try c.decodeIfPresent(String.self, forKey: .recordingLabel) ?? title
        transcriptStatus = try c.decode(PipelineStatus.self, forKey: .transcriptStatus)
        summaryStatus = try c.decode(PipelineStatus.self, forKey: .summaryStatus)
        briefStatus = try c.decodeIfPresent(PipelineStatus.self, forKey: .briefStatus) ?? .pending
        exportStatus = try c.decode(PipelineStatus.self, forKey: .exportStatus)
        audioFileName = try c.decode(String.self, forKey: .audioFileName)
        posterFileName = try c.decodeIfPresent(String.self, forKey: .posterFileName)
        audioOnlyExport = try c.decodeIfPresent(Bool.self, forKey: .audioOnlyExport) ?? false
        titleSetByUser = try c.decodeIfPresent(Bool.self, forKey: .titleSetByUser) ?? false
    }
}

struct MeetingTopicPoint: Codable, Equatable, Hashable, Identifiable {
    var id: String { title + detail }
    var title: String
    var detail: String
}

struct MeetingTopic: Codable, Equatable, Hashable, Identifiable {
    var id: String { name + tag + summary }
    var name: String
    var tag: String
    var summary: String
    var points: [MeetingTopicPoint]
    /// Optional large callout, e.g. "20 courses".
    var highlight: String?
    var highlightLabel: String?

    enum CodingKeys: String, CodingKey {
        case name, tag, summary, points, highlight, highlightLabel
    }

    init(
        name: String,
        tag: String = "",
        summary: String,
        points: [MeetingTopicPoint] = [],
        highlight: String? = nil,
        highlightLabel: String? = nil
    ) {
        self.name = name
        self.tag = tag
        self.summary = summary
        self.points = points
        self.highlight = highlight
        self.highlightLabel = highlightLabel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? ""
        summary = try c.decode(String.self, forKey: .summary)
        points = try c.decodeIfPresent([MeetingTopicPoint].self, forKey: .points) ?? []
        highlight = try c.decodeIfPresent(String.self, forKey: .highlight)
        highlightLabel = try c.decodeIfPresent(String.self, forKey: .highlightLabel)
    }
}

struct MeetingActionItem: Codable, Equatable, Hashable, Identifiable {
    var id: String { task + (owner ?? "") + (ownerRole ?? "") }
    var task: String
    var owner: String?
    var ownerRole: String?

    enum CodingKeys: String, CodingKey {
        case task, owner, ownerRole
    }

    init(task: String, owner: String? = nil, ownerRole: String? = nil) {
        self.task = task
        self.owner = owner
        self.ownerRole = ownerRole
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        task = try c.decode(String.self, forKey: .task)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        ownerRole = try c.decodeIfPresent(String.self, forKey: .ownerRole)
    }
}

struct MeetingBrief: Codable, Equatable, Hashable {
    /// Short meeting-type pill, e.g. "1-on-1 Strategic Alignment".
    var kind: String
    var title: String
    /// One-line lede under the title.
    var subtitle: String
    var decisions: [String]
    var topics: [MeetingTopic]
    var actionItems: [MeetingActionItem]

    enum CodingKeys: String, CodingKey {
        case kind, title, subtitle, decisions, topics, actionItems
    }

    init(
        kind: String = "Meeting notes",
        title: String,
        subtitle: String = "",
        decisions: [String] = [],
        topics: [MeetingTopic],
        actionItems: [MeetingActionItem]
    ) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.decisions = decisions
        self.topics = topics
        self.actionItems = actionItems
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "Meeting notes"
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        topics = try c.decodeIfPresent([MeetingTopic].self, forKey: .topics) ?? []
        actionItems = try c.decodeIfPresent([MeetingActionItem].self, forKey: .actionItems) ?? []
    }

    /// Named owners first (first-seen order), then a single nil-owner group for ownerless tasks.
    /// Never invents placeholder people like "Unassigned" / "John Doe".
    var actionOwners: [(owner: String?, role: String?, tasks: [String])] {
        var namedOrder: [String] = []
        var roles: [String: String] = [:]
        var namedTasks: [String: [String]] = [:]
        var ownerless: [String] = []

        for item in actionItems {
            let task = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { continue }
            let name = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty {
                if !namedOrder.contains(name) { namedOrder.append(name) }
                if let role = item.ownerRole?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty {
                    roles[name] = role
                }
                namedTasks[name, default: []].append(task)
            } else {
                ownerless.append(task)
            }
        }

        var groups = namedOrder.map { (Optional($0), roles[$0], namedTasks[$0] ?? []) }
        if !ownerless.isEmpty {
            groups.append((nil, nil, ownerless))
        }
        return groups
    }
}

// MARK: - Speaker transcripts (issue #12, format version 1)

/// A speaker-attributed transcript, stored next to `transcript.md` as `transcript.json`.
///
/// When a note has one, `transcript.md` is a rendering of it (`rendered()`): one paragraph per
/// speaker turn, labelled with the speaker's confirmed name or "Speaker N". The Plaud Remote server
/// (speaker transcripts, PR #19: `server/plaud_remote/speakers.py`, `render`) renders the same way,
/// so its `transcript` text equals `anonymousRendering()` of the document it sends. Keep the two
/// renderers in step: the same fixture is copied into TranscriptDocumentTests and test_speakers.py.
struct TranscriptDocument: Codable, Equatable {
    static let fileName = "transcript.json"
    /// Written by a transcription engine during a pass; committed or discarded by the pipeline.
    static let pendingFileName = "transcript.pending.json"

    var version: Int
    var language: String?
    var duration: Double?
    var source: Source?
    var speakers: [Speaker]
    var segments: [Segment]

    struct Source: Codable, Equatable {
        var provider: String?
        var model: String?
        var diarized: Bool?
    }

    struct Suggestion: Codable, Equatable {
        var name: String
        var source: String?
        var confidence: Double?
        var evidence: String?
    }

    struct Speaker: Codable, Equatable {
        var id: String
        var name: String?
        var nameSource: String?
        var suggestion: Suggestion?

        enum CodingKeys: String, CodingKey {
            case id, name, suggestion
            case nameSource = "name_source"
        }

        /// A name the user typed or accepted; automated steps never replace it.
        var userName: String? {
            guard nameSource == "user", let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return name
        }
    }

    struct Segment: Codable, Equatable {
        var start: Double?
        var end: Double?
        var speaker: String?
        var text: String
    }

    /// The document in `noteDirectory` (`fileName` by default), or nil if missing or unreadable.
    static func read(in noteDirectory: URL, fileName: String = fileName) -> TranscriptDocument? {
        guard let data = try? Data(contentsOf: noteDirectory.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(TranscriptDocument.self, from: data)
    }

    func write(in noteDirectory: URL, fileName: String = fileName) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: noteDirectory.appendingPathComponent(fileName), options: .atomic)
    }

    /// Sets (or, with an empty name, clears) the confirmed name of speaker `id`.
    mutating func setName(_ name: String, forSpeaker id: String) {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return }
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        speakers[index].name = typed.isEmpty ? nil : typed
        speakers[index].nameSource = typed.isEmpty ? nil : "user"
    }

    /// `transcript.md` for this document.
    func rendered() -> String { render(names: true) }

    /// The rendering without any names: what the server sent as the job's `transcript`.
    func anonymousRendering() -> String { render(names: false) }

    private func render(names: Bool) -> String {
        let byId = Dictionary(speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let label: (Speaker) -> String? = { names ? ($0.name?.isEmpty == false ? $0.name : nil) : nil }
        // One speaker without a name: plain text ("Speaker 1:" on every line of a voice memo is noise).
        let singleUnnamed = speakers.count == 1 && label(speakers[0]) == nil
        return segments.compactMap { segment -> String? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            guard let id = segment.speaker, let speaker = byId[id], !singleUnnamed else { return text }
            return "\(label(speaker) ?? "Speaker \(speaker.id.dropFirst())"): \(text)"
        }.joined(separator: "\n\n")
    }

    /// This document updated from a newer copy of the same transcript from the server: takes its
    /// name suggestions, but never touches a name the user set. Returns nil if `server` is a
    /// different transcript.
    func merging(server: TranscriptDocument) -> TranscriptDocument? {
        guard server.anonymousRendering() == anonymousRendering() else { return nil }
        var merged = self
        for index in merged.speakers.indices where merged.speakers[index].userName == nil {
            let id = merged.speakers[index].id
            merged.speakers[index].suggestion = server.speakers.first { $0.id == id }?.suggestion
        }
        return merged
    }
}
