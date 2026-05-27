import Foundation
import LaunchKitCore
import LaunchKitPolicy

public enum AgentStatus: String, Codable, CaseIterable, Sendable {
    case unavailable
    case starting
    case running
    case needsUserApproval
    case needsUnlock
    case recovering
    case stopped
}

public enum AgentJobKind: String, Codable, CaseIterable, Sendable {
    case scan
    case build
    case screenshotCapture
    case certificateMonitor
    case applePolling
    case complianceAudit
    case assetUpload
}

public enum AgentJobState: String, Codable, CaseIterable, Sendable {
    case queued
    case leased
    case running
    case needsApproval
    case needsUnlock
    case succeeded
    case failed
    case failedRecoverable
    case cancelled
    case stale
    case interrupted
}

public struct AgentJob: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var workflowID: WorkflowID
    public var kind: AgentJobKind
    public var state: AgentJobState
    public var priority: Int
    public var action: LaunchKitAction
    public var createdAt: Date
    public var updatedAt: Date
    public var leaseOwner: String?
    public var heartbeatAt: Date?

    public init(
        id: UUID = UUID(),
        workflowID: WorkflowID,
        kind: AgentJobKind,
        state: AgentJobState = .queued,
        priority: Int = 0,
        action: LaunchKitAction,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        leaseOwner: String? = nil,
        heartbeatAt: Date? = nil
    ) {
        self.id = id
        self.workflowID = workflowID
        self.kind = kind
        self.state = state
        self.priority = priority
        self.action = action
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.leaseOwner = leaseOwner
        self.heartbeatAt = heartbeatAt
    }
}

public struct AgentRecoveryPlanner: Sendable {
    public init() {}

    public func recoveredState(for job: AgentJob, policy: PolicyDecision) -> AgentJobState {
        switch job.state {
        case .running, .leased:
            return policy.canRunAutomatically ? .interrupted : .needsApproval
        case .needsUnlock:
            return .needsUnlock
        case .needsApproval:
            return .needsApproval
        default:
            return job.state
        }
    }
}

