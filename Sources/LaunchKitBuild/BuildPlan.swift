import Foundation
import LaunchKitCore
import LaunchKitExecution
import LaunchKitScanner

public struct BuildPlan: Codable, Hashable, Sendable {
    public var scheme: String?
    public var workspacePath: String?
    public var projectPath: String?
    public var configuration: String
    public var archivePath: String
    public var commands: [CommandSpec]

    public init(
        scheme: String?,
        workspacePath: String?,
        projectPath: String?,
        configuration: String = "Release",
        archivePath: String,
        commands: [CommandSpec]
    ) {
        self.scheme = scheme
        self.workspacePath = workspacePath
        self.projectPath = projectPath
        self.configuration = configuration
        self.archivePath = archivePath
        self.commands = commands
    }
}

public struct BuildPlanGenerator: Sendable {
    public init() {}

    public func makeArchivePlan(
        scan: ProjectScanResult,
        scheme: String?,
        archivePath: String
    ) -> BuildPlan {
        let workspace = scan.workspaces.first?.path
        let project = scan.xcodeProjects.first?.path

        var arguments: [String] = ["archive", "-configuration", "Release", "-archivePath", archivePath]
        if let workspace {
            arguments += ["-workspace", workspace]
        } else if let project {
            arguments += ["-project", project]
        }
        if let scheme {
            arguments += ["-scheme", scheme]
        }

        let action = LaunchKitAction(
            title: "Archive app locally",
            explanation: "Run xcodebuild archive in the selected repository. This produces a local archive but does not upload or submit anything.",
            category: .safeRead,
            risk: .medium,
            affectedPaths: [archivePath],
            isReversible: true,
            rollbackSummary: "Delete the generated archive."
        )

        let command = CommandSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: arguments,
            workingDirectory: scan.rootURL,
            action: action
        )

        return BuildPlan(
            scheme: scheme,
            workspacePath: workspace,
            projectPath: project,
            archivePath: archivePath,
            commands: [command]
        )
    }
}

