import Foundation
import LaunchKitCore
import LaunchKitPolicy

public struct CommandSpec: Codable, Hashable, Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var workingDirectory: URL
    public var environment: [String: String]
    public var redactedEnvironmentKeys: Set<String>
    public var action: LaunchKitAction

    public init(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String] = [:],
        redactedEnvironmentKeys: Set<String> = [],
        action: LaunchKitAction
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.redactedEnvironmentKeys = redactedEnvironmentKeys
        self.action = action
    }

    public var displayCommand: String {
        ([executableURL.path] + arguments).joined(separator: " ")
    }

    public var redactedEnvironment: [String: String] {
        environment.mapValues { $0 }.merging(
            Dictionary(uniqueKeysWithValues: redactedEnvironmentKeys.map { ($0, "<redacted>") }),
            uniquingKeysWith: { _, redacted in redacted }
        )
    }
}

public struct CommandResult: Codable, Hashable, Sendable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String
    public var startedAt: Date
    public var finishedAt: Date

    public init(
        exitCode: Int32,
        standardOutput: String,
        standardError: String,
        startedAt: Date,
        finishedAt: Date
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public enum CommandRunnerError: Error, LocalizedError, Sendable {
    case approvalRequired(PolicyDecision)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .approvalRequired(decision):
            return decision.reason
        case let .launchFailed(message):
            return message
        }
    }
}

public actor ProcessCommandRunner {
    private let policyEngine: PolicyEngine

    public init(policyEngine: PolicyEngine = PolicyEngine()) {
        self.policyEngine = policyEngine
    }

    public func run(_ spec: CommandSpec, approvalGranted: Bool = false) async throws -> CommandResult {
        let decision = policyEngine.decision(for: spec.action)
        guard decision.canRunAutomatically || approvalGranted else {
            throw CommandRunnerError.approvalRequired(decision)
        }

        return try await Task.detached(priority: .utility) {
            let startedAt = Date()
            let process = Process()
            process.executableURL = spec.executableURL
            process.arguments = spec.arguments
            process.currentDirectoryURL = spec.workingDirectory
            process.environment = spec.environment.isEmpty ? nil : spec.environment

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                throw CommandRunnerError.launchFailed(error.localizedDescription)
            }

            process.waitUntilExit()

            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

            return CommandResult(
                exitCode: process.terminationStatus,
                standardOutput: String(decoding: outputData, as: UTF8.self),
                standardError: String(decoding: errorData, as: UTF8.self),
                startedAt: startedAt,
                finishedAt: Date()
            )
        }.value
    }
}

