import XCTest
@testable import InboxCore

final class HandTaskProgressTests: XCTestCase {
    func testOnlyFreshActivityForTheOwnedTurnAdvancesProgress() throws {
        var progress = HandTaskProgress(turnID: "owned")
        func event(_ cursor: String, turn: String = "owned", type: String = "tool.result") throws -> AgentEvent {
            try AgentEvent(.object(["type": .string("event"), "turn_id": .string(turn),
                                   "event": .object(["type": .string(type)])]), cursor: cursor)
        }
        XCTAssertTrue(progress.receive(try event("9007199254740993")))
        XCTAssertEqual(progress.completedUnits, 1)
        XCTAssertFalse(progress.receive(try event("9007199254740993")))
        XCTAssertFalse(progress.receive(try event("9007199254740992")))
        XCTAssertFalse(progress.receive(try event("9007199254740994", turn: "other")))
        XCTAssertFalse(progress.receive(try event("9007199254740995", type: "heartbeat")))
        XCTAssertEqual(progress.completedUnits, 1)
        XCTAssertTrue(progress.receive(try event("9007199254740996", type: "assistant.delta")))
        XCTAssertEqual(progress.completedUnits, 2)
        XCTAssertEqual(progress.detail, "Writing response")
    }
}
