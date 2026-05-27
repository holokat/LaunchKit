import Foundation
import LaunchKitCore

public struct PolicyDecision: Codable, Hashable, Sendable {
    public var requirement: ApprovalRequirement
    public var reason: String
    public var canRunAutomatically: Bool
    public var requiresRollbackCheckpoint: Bool

    public init(
        requirement: ApprovalRequirement,
        reason: String,
        canRunAutomatically: Bool,
        requiresRollbackCheckpoint: Bool
    ) {
        self.requirement = requirement
        self.reason = reason
        self.canRunAutomatically = canRunAutomatically
        self.requiresRollbackCheckpoint = requiresRollbackCheckpoint
    }
}

public struct PolicyEngine: Sendable {
    public init() {}

    public func decision(for action: LaunchKitAction) -> PolicyDecision {
        switch action.category {
        case .safeRead:
            return PolicyDecision(
                requirement: .autoRun,
                reason: "This only reads local project state.",
                canRunAutomatically: true,
                requiresRollbackCheckpoint: false
            )
        case .safeReversibleWrite:
            return PolicyDecision(
                requirement: .reviewRequired,
                reason: "This changes local files but can be rolled back from a checkpoint.",
                canRunAutomatically: action.isReversible,
                requiresRollbackCheckpoint: true
            )
        case .riskyWrite:
            return PolicyDecision(
                requirement: .reviewRequired,
                reason: "This may affect build, signing, or runtime behavior and needs review.",
                canRunAutomatically: false,
                requiresRollbackCheckpoint: true
            )
        case .publicFacing:
            return PolicyDecision(
                requirement: .explicitApproval,
                reason: "This affects public App Store text, screenshots, or customer-visible content.",
                canRunAutomatically: false,
                requiresRollbackCheckpoint: true
            )
        case .revenueLegal:
            return PolicyDecision(
                requirement: .explicitApproval,
                reason: "This affects pricing, subscriptions, privacy, legal, or revenue settings.",
                canRunAutomatically: false,
                requiresRollbackCheckpoint: true
            )
        case .destructive:
            return PolicyDecision(
                requirement: .explicitApproval,
                reason: "This can remove data, revoke access, or make destructive repository changes.",
                canRunAutomatically: false,
                requiresRollbackCheckpoint: true
            )
        }
    }
}

