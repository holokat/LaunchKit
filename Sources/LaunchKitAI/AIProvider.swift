import Foundation
import LaunchKitCore
import LaunchKitPolicy

public enum AIProviderKind: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case local
}

public struct AIRequest: Codable, Hashable, Sendable {
    public var purpose: String
    public var inputSummary: String
    public var allowedActions: [ActionCategory]
    public var redactedContext: [String: String]

    public init(
        purpose: String,
        inputSummary: String,
        allowedActions: [ActionCategory],
        redactedContext: [String: String] = [:]
    ) {
        self.purpose = purpose
        self.inputSummary = inputSummary
        self.allowedActions = allowedActions
        self.redactedContext = redactedContext
    }
}

public struct AIResponse: Codable, Hashable, Sendable {
    public var summary: String
    public var proposedActions: [LaunchKitAction]
    public var requiresHumanReview: Bool

    public init(summary: String, proposedActions: [LaunchKitAction], requiresHumanReview: Bool) {
        self.summary = summary
        self.proposedActions = proposedActions
        self.requiresHumanReview = requiresHumanReview
    }
}

public protocol AIProvider: Sendable {
    var kind: AIProviderKind { get }
    func complete(_ request: AIRequest) async throws -> AIResponse
}

public struct RuleBasedExplanationProvider: AIProvider {
    public let kind: AIProviderKind = .local

    public init() {}

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        AIResponse(
            summary: "LaunchKit analyzed \(request.purpose). External AI providers are not connected yet, so this response is generated locally from deterministic scan results.",
            proposedActions: [],
            requiresHumanReview: false
        )
    }
}

