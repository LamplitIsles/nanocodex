import Foundation

/// Count actual activity for one durable turn. Replayed events, other turns,
/// and heartbeats must never manufacture progress to extend background time.
public struct HandTaskProgress: Sendable {
    public let turnID: String
    public private(set) var cursor = Cursor.zero
    public private(set) var completedUnits: Int64 = 0
    public private(set) var detail = "Waiting for agent"
    public init(turnID: String, after cursor: Cursor = .zero) { self.turnID = turnID; self.cursor = cursor }

    @discardableResult
    public mutating func receive(_ event: AgentEvent) -> Bool {
        guard event.cursor > cursor else { return false }
        cursor = event.cursor
        guard event.turnID == turnID else { return false }
        switch event.type {
        case "turn_completed": detail = "Completed"
        case "turn_failed": detail = "Failed"
        case "turn_cancelled": detail = "Stopped"
        case "event":
            switch event.data["event"]["type"].string {
            case "run.started": detail = "Agent working"
            case "tool.call": detail = "Using tools"
            case "tool.result": detail = "Tool finished"
            case "assistant.delta", "assistant.message": detail = "Writing response"
            case "reasoning.summary.delta": detail = "Thinking"
            default: return false
            }
        default: return false
        }
        completedUnits += 1
        return true
    }
}
