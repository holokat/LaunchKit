import Foundation
import LaunchKitCore

public enum EventLevel: String, Codable, CaseIterable, Sendable {
    case debug
    case info
    case warning
    case error
    case fault
}

public enum EventCategory: String, Codable, CaseIterable, Sendable {
    case workflow
    case command
    case apple
    case ai
    case rollback
    case asset
    case compliance
    case persistence
    case security
}

public enum PrivacyClassification: String, Codable, CaseIterable, Sendable {
    case publicSafe
    case localOnly
    case redacted
    case sensitiveBlocked
}

public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null
}

public struct TraceContext: Codable, Hashable, Sendable {
    public var traceID: UUID
    public var workflowID: WorkflowID?
    public var actionID: ActionID?
    public var spanID: UUID?
    public var parentSpanID: UUID?

    public init(
        traceID: UUID = UUID(),
        workflowID: WorkflowID? = nil,
        actionID: ActionID? = nil,
        spanID: UUID? = nil,
        parentSpanID: UUID? = nil
    ) {
        self.traceID = traceID
        self.workflowID = workflowID
        self.actionID = actionID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
    }
}

public struct ObservabilityEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var trace: TraceContext
    public var timestamp: Date
    public var level: EventLevel
    public var category: EventCategory
    public var message: String
    public var attributes: [String: JSONValue]
    public var privacy: PrivacyClassification

    public init(
        id: UUID = UUID(),
        trace: TraceContext,
        timestamp: Date = Date(),
        level: EventLevel,
        category: EventCategory,
        message: String,
        attributes: [String: JSONValue] = [:],
        privacy: PrivacyClassification
    ) {
        self.id = id
        self.trace = trace
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.attributes = attributes
        self.privacy = privacy
    }
}

