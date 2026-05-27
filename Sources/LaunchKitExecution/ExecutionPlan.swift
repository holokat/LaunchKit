import Foundation
import LaunchKitCore
import LaunchKitPolicy

public enum CommandKind: String, Codable, CaseIterable, Sendable {
    case gitRead
    case xcodeRead
    case xcodeBuild
    case xcodeProvisioning
    case plistValidation
    case codeSigningRead
    case packageManager
    case transporterUpload
}

public enum TrustedExecutable: String, Codable, CaseIterable, Sendable {
    case git = "/usr/bin/git"
    case xcodebuild = "/usr/bin/xcodebuild"
    case xcrun = "/usr/bin/xcrun"
    case plutil = "/usr/bin/plutil"
    case codesign = "/usr/bin/codesign"
    case security = "/usr/bin/security"
    case swift = "/usr/bin/swift"
    case bundle = "/usr/bin/bundle"
    case pod = "/usr/bin/pod"

    public var url: URL { URL(fileURLWithPath: rawValue) }
}

public struct ValidatedArgument: Codable, Hashable, Sendable {
    public var value: String
    public var isSensitive: Bool

    public init(_ value: String, isSensitive: Bool = false) {
        self.value = value
        self.isSensitive = isSensitive
    }
}

public struct ExecutionPlan: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: CommandKind
    public var executable: TrustedExecutable
    public var arguments: [ValidatedArgument]
    public var workingDirectory: URL
    public var allowedReadRoots: [URL]
    public var allowedWriteRoots: [URL]
    public var timeoutSeconds: TimeInterval
    public var action: LaunchKitAction
    public var checkpointID: UUID?

    public init(
        id: UUID = UUID(),
        kind: CommandKind,
        executable: TrustedExecutable,
        arguments: [ValidatedArgument],
        workingDirectory: URL,
        allowedReadRoots: [URL],
        allowedWriteRoots: [URL] = [],
        timeoutSeconds: TimeInterval = 600,
        action: LaunchKitAction,
        checkpointID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.allowedReadRoots = allowedReadRoots
        self.allowedWriteRoots = allowedWriteRoots
        self.timeoutSeconds = timeoutSeconds
        self.action = action
        self.checkpointID = checkpointID
    }

    public var displayCommand: String {
        ([executable.rawValue] + arguments.map { $0.isSensitive ? "<redacted>" : $0.value }).joined(separator: " ")
    }
}

public enum ExecutionPolicyError: Error, LocalizedError, Sendable {
    case executableDoesNotMatchKind
    case approvalRequired(PolicyDecision)
    case checkpointRequired

    public var errorDescription: String? {
        switch self {
        case .executableDoesNotMatchKind:
            return "The selected executable is not allowed for this command kind."
        case let .approvalRequired(decision):
            return decision.reason
        case .checkpointRequired:
            return "This write requires a rollback checkpoint before execution."
        }
    }
}

public struct CommandPolicyValidator: Sendable {
    private let policyEngine: PolicyEngine

    public init(policyEngine: PolicyEngine = PolicyEngine()) {
        self.policyEngine = policyEngine
    }

    public func validate(_ plan: ExecutionPlan, approvalGranted: Bool = false) throws -> PolicyDecision {
        guard allowedExecutables(for: plan.kind).contains(plan.executable) else {
            throw ExecutionPolicyError.executableDoesNotMatchKind
        }

        let decision = policyEngine.decision(for: plan.action)
        guard decision.canRunAutomatically || approvalGranted else {
            throw ExecutionPolicyError.approvalRequired(decision)
        }

        if decision.requiresRollbackCheckpoint && plan.checkpointID == nil {
            throw ExecutionPolicyError.checkpointRequired
        }

        return decision
    }

    private func allowedExecutables(for kind: CommandKind) -> Set<TrustedExecutable> {
        switch kind {
        case .gitRead:
            return [.git]
        case .xcodeRead, .xcodeBuild, .xcodeProvisioning:
            return [.xcodebuild, .xcrun]
        case .plistValidation:
            return [.plutil]
        case .codeSigningRead:
            return [.codesign, .security]
        case .packageManager:
            return [.swift, .bundle, .pod]
        case .transporterUpload:
            return [.xcrun]
        }
    }
}

