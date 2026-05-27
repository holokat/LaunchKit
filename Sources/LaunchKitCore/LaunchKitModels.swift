import Foundation

public struct LaunchKitProject: Codable, Hashable, Sendable, Identifiable {
    public let id: ProjectID
    public var displayName: String
    public var rootURL: URL
    public var detectedPlatforms: [ApplePlatform]
    public var lastScanAt: Date?

    public init(
        id: ProjectID = ProjectID(),
        displayName: String,
        rootURL: URL,
        detectedPlatforms: [ApplePlatform] = [],
        lastScanAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.rootURL = rootURL
        self.detectedPlatforms = detectedPlatforms
        self.lastScanAt = lastScanAt
    }
}

public enum ApplePlatform: String, Codable, CaseIterable, Sendable {
    case iOS
    case iPadOS
    case macOS
    case tvOS
    case watchOS
    case visionOS
}

public struct DiagnosticFinding: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var explanation: String
    public var severity: DiagnosticSeverity
    public var risk: RiskLevel
    public var affectedPaths: [String]
    public var recommendedFix: String?
    public var appleReference: String?
    public var autoFixAction: LaunchKitAction?

    public init(
        id: UUID = UUID(),
        title: String,
        explanation: String,
        severity: DiagnosticSeverity,
        risk: RiskLevel,
        affectedPaths: [String] = [],
        recommendedFix: String? = nil,
        appleReference: String? = nil,
        autoFixAction: LaunchKitAction? = nil
    ) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.severity = severity
        self.risk = risk
        self.affectedPaths = affectedPaths
        self.recommendedFix = recommendedFix
        self.appleReference = appleReference
        self.autoFixAction = autoFixAction
    }
}

public struct LaunchKitAction: Codable, Hashable, Sendable, Identifiable {
    public var id: ActionID
    public var title: String
    public var explanation: String
    public var category: ActionCategory
    public var risk: RiskLevel
    public var affectedPaths: [String]
    public var isReversible: Bool
    public var rollbackSummary: String?

    public init(
        id: ActionID = ActionID(),
        title: String,
        explanation: String,
        category: ActionCategory,
        risk: RiskLevel,
        affectedPaths: [String] = [],
        isReversible: Bool,
        rollbackSummary: String? = nil
    ) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.category = category
        self.risk = risk
        self.affectedPaths = affectedPaths
        self.isReversible = isReversible
        self.rollbackSummary = rollbackSummary
    }
}

public struct ReleaseWorkflow: Codable, Hashable, Sendable, Identifiable {
    public let id: WorkflowID
    public var project: LaunchKitProject
    public var phase: WorkflowPhase
    public var findings: [DiagnosticFinding]
    public var plannedActions: [LaunchKitAction]
    public var timeline: [WorkflowEvent]

    public init(
        id: WorkflowID = WorkflowID(),
        project: LaunchKitProject,
        phase: WorkflowPhase = .onboarding,
        findings: [DiagnosticFinding] = [],
        plannedActions: [LaunchKitAction] = [],
        timeline: [WorkflowEvent] = []
    ) {
        self.id = id
        self.project = project
        self.phase = phase
        self.findings = findings
        self.plannedActions = plannedActions
        self.timeline = timeline
    }
}

public struct WorkflowEvent: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var occurredAt: Date
    public var phase: WorkflowPhase
    public var title: String
    public var detail: String
    public var risk: RiskLevel

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        phase: WorkflowPhase,
        title: String,
        detail: String,
        risk: RiskLevel = .informational
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.phase = phase
        self.title = title
        self.detail = detail
        self.risk = risk
    }
}

