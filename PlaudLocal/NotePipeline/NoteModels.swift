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
    var title: String
    var transcriptStatus: PipelineStatus
    var summaryStatus: PipelineStatus
    var exportStatus: PipelineStatus
    var audioFileName: String
}
