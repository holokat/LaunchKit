import Foundation

public enum RiskLevel: String, Codable, CaseIterable, Sendable {
    case informational
    case low
    case medium
    case high
    case critical
}

public enum ActionCategory: String, Codable, CaseIterable, Sendable {
    case safeRead
    case safeReversibleWrite
    case riskyWrite
    case publicFacing
    case revenueLegal
    case destructive
}

public enum ApprovalRequirement: String, Codable, Sendable {
    case autoRun
    case reviewRequired
    case explicitApproval
}

public enum DiagnosticSeverity: String, Codable, CaseIterable, Sendable {
    case info
    case warning
    case error
    case blocker
}

public enum WorkflowPhase: String, Codable, CaseIterable, Sendable, Identifiable {
    case onboarding
    case scanning
    case planning
    case fixing
    case building
    case screenshots
    case metadata
    case payments
    case compliance
    case submission
    case completed

    public var id: String { rawValue }
}

