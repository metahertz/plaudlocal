import XCTest
@testable import PlaudLocal

final class BriefBuilderTests: XCTestCase {
    func test_heuristicTitleAndPosterName() async throws {
        let builder = BriefBuilder(forceHeuristic: true)
        let brief = try await builder.build(
            transcript: "We decided to ship the beta on Friday. Alice will own the release checklist.",
            summary: "Shipping beta Friday; Alice owns release checklist."
        )
        XCTAssertFalse(brief.title.isEmpty)
        XCTAssertFalse(brief.kind.isEmpty)
        XCTAssertFalse(brief.topics.isEmpty)
        XCTAssertFalse(brief.topics[0].points.isEmpty)

        let name = BriefBuilder.posterFileName(sessionId: 1_730_000_000, title: "Weekly Sync / Launch")
        XCTAssertTrue(name.hasSuffix(".png"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.contains("Weekly"))
    }

    func test_sanitizeRemovesPathCharacters() {
        let safe = BriefBuilder.sanitizeFileComponent("A:B/C*D?")
        XCTAssertFalse(safe.contains(":"))
        XCTAssertFalse(safe.contains("/"))
        XCTAssertFalse(safe.contains("*"))
    }

    func test_groundingDropsInventedActionsAndPlaceholderOwners() {
        let source = "We talked about morale and the APAC offsite options in Singapore."
        let dirty = MeetingBrief(
            kind: "1-on-1",
            title: "APAC sync",
            subtitle: "Morale and offsite",
            decisions: ["Invented decision about Mars colony"],
            topics: [],
            actionItems: [
                MeetingActionItem(task: "Follow up with finance on budget", owner: "John Doe", ownerRole: "PM"),
                MeetingActionItem(task: "todo", owner: "Someone"),
                MeetingActionItem(task: "Confirm Singapore offsite dates", owner: nil),
            ]
        )
        let clean = BriefGrounding.sanitize(dirty, against: source)
        XCTAssertTrue(clean.decisions.isEmpty)
        XCTAssertTrue(clean.actionItems.isEmpty || clean.actionItems.allSatisfy { $0.owner == nil })
        XCTAssertFalse(clean.actionItems.contains { ($0.owner ?? "").localizedCaseInsensitiveContains("John") })
        XCTAssertFalse(clean.actionItems.contains { BriefGrounding.isPlaceholderName($0.owner ?? "") })
    }

    func test_heuristicDoesNotInventActionsWithoutMarkers() async throws {
        let builder = BriefBuilder(forceHeuristic: true)
        let brief = try await builder.build(
            transcript: "We discussed team morale and Singapore versus India for the offsite.",
            summary: "Morale and offsite location options."
        )
        XCTAssertTrue(brief.actionItems.isEmpty)
    }

    func test_actionOwnersOmitsFakeUnassignedLabel() {
        let brief = MeetingBrief(
            title: "Sync",
            topics: [],
            actionItems: [MeetingActionItem(task: "Send the notes", owner: nil)]
        )
        let groups = brief.actionOwners
        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups[0].owner)
        XCTAssertEqual(groups[0].tasks, ["Send the notes"])
    }
}
