import Foundation
import LaunchKitCore

public enum CodexCLIError: Error, LocalizedError, Sendable {
    case missingExecutable
    case commandFailed(Int32, String)
    case timedOut(String)
    case emptyOutput

    public var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return "Codex CLI is not installed."
        case let .commandFailed(status, output):
            return "Codex command failed with exit code \(status): \(output)"
        case let .timedOut(command):
            return "Codex command timed out: \(command)"
        case .emptyOutput:
            return "Codex did not return an output message."
        }
    }
}

public struct CodexAuthenticationState: Codable, Hashable, Sendable {
    public var isInstalled: Bool
    public var isLoggedIn: Bool
    public var executablePath: String?
    public var version: String?
    public var statusText: String

    public init(
        isInstalled: Bool,
        isLoggedIn: Bool,
        executablePath: String?,
        version: String?,
        statusText: String
    ) {
        self.isInstalled = isInstalled
        self.isLoggedIn = isLoggedIn
        self.executablePath = executablePath
        self.version = version
        self.statusText = statusText
    }
}

public struct CodexCommandResult: Codable, Hashable, Sendable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var combinedOutput: String {
        [standardOutput, standardError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

public actor CodexCLIClient {
    private let explicitExecutablePath: String?
    private let fileManager: FileManager

    public init(executablePath: String? = nil, fileManager: FileManager = .default) {
        self.explicitExecutablePath = executablePath
        self.fileManager = fileManager
    }

    public func probeAuthentication() async -> CodexAuthenticationState {
        guard let codex = resolveCodexExecutable() else {
            return CodexAuthenticationState(
                isInstalled: false,
                isLoggedIn: false,
                executablePath: nil,
                version: nil,
                statusText: "Codex CLI is not installed."
            )
        }

        let versionResult = await runProcessOrFailure(
            executablePath: codex,
            arguments: ["--version"],
            currentDirectoryURL: nil,
            timeout: 20
        )
        let statusResult = await runProcessOrFailure(
            executablePath: codex,
            arguments: ["login", "status"],
            currentDirectoryURL: nil,
            timeout: 20
        )

        let version = versionResult.exitCode == 0 ? versionResult.combinedOutput : nil
        return CodexAuthenticationState(
            isInstalled: true,
            isLoggedIn: statusResult.exitCode == 0,
            executablePath: codex,
            version: version?.isEmpty == false ? version : nil,
            statusText: statusResult.combinedOutput.isEmpty ? "Codex login status unavailable." : statusResult.combinedOutput
        )
    }

    public func installWithNPM() async throws -> CodexAuthenticationState {
        let npm = resolveExecutable(named: "npm", candidates: [
            "/opt/homebrew/bin/npm",
            "/usr/local/bin/npm",
            "/usr/bin/npm"
        ])
        guard let npm else {
            throw CodexCLIError.commandFailed(-1, "npm is not installed.")
        }

        let result = try await runProcess(
            executablePath: npm,
            arguments: ["install", "-g", "@openai/codex"],
            currentDirectoryURL: nil,
            timeout: 600
        )
        guard result.exitCode == 0 else {
            throw CodexCLIError.commandFailed(result.exitCode, result.combinedOutput)
        }
        return await probeAuthentication()
    }

    public func login(deviceAuth: Bool = false) async throws -> CodexAuthenticationState {
        guard let codex = resolveCodexExecutable() else {
            throw CodexCLIError.missingExecutable
        }

        let arguments = deviceAuth ? ["login", "--device-auth"] : ["login"]
        let result = try await runProcess(
            executablePath: codex,
            arguments: arguments,
            currentDirectoryURL: nil,
            timeout: 900
        )
        guard result.exitCode == 0 else {
            throw CodexCLIError.commandFailed(result.exitCode, result.combinedOutput)
        }
        return await probeAuthentication()
    }

    public func complete(
        prompt: String,
        workingDirectoryURL: URL?,
        modelOverride: String? = nil,
        timeout: TimeInterval = 900
    ) async throws -> String {
        guard let codex = resolveCodexExecutable() else {
            throw CodexCLIError.missingExecutable
        }

        let outputURL = fileManager.temporaryDirectory
            .appending(path: "launchkit-codex-\(UUID().uuidString).txt")
        var arguments = [
            "exec",
            "-c", "approval_policy=never",
            "--sandbox", "read-only",
            "--skip-git-repo-check",
            "--output-last-message", outputURL.path
        ]
        if let modelOverride, !modelOverride.isEmpty {
            arguments += ["--model", modelOverride]
        }
        if let workingDirectoryURL {
            arguments += ["-C", workingDirectoryURL.path]
        }
        arguments.append(prompt)

        let result = try await runProcess(
            executablePath: codex,
            arguments: arguments,
            currentDirectoryURL: workingDirectoryURL,
            timeout: timeout
        )
        guard result.exitCode == 0 else {
            throw CodexCLIError.commandFailed(result.exitCode, result.combinedOutput)
        }

        let fileOutput = (try? String(contentsOf: outputURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try? fileManager.removeItem(at: outputURL)

        let output = fileOutput?.isEmpty == false
            ? fileOutput!
            : result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw CodexCLIError.emptyOutput }
        return output
    }

    public nonisolated func releasePlanPrompt(scan: ProjectScanResult?) -> String {
        var facts = "No project scan is selected yet. Generate the next release setup plan from first principles."
        if let scan {
            facts = """
            Project type: \(scan.projectType.rawValue)
            Xcode projects: \(scan.xcodeProjects.map(\.path).joined(separator: ", "))
            Workspaces: \(scan.workspaces.map(\.path).joined(separator: ", "))
            Package managers: \(scan.packageManagers.map(\.rawValue).joined(separator: ", "))
            Capabilities: \(scan.capabilities.map(\.rawValue).joined(separator: ", "))
            Findings:
            \(scan.findings.map { "- \($0.title): \($0.explanation)" }.joined(separator: "\n"))
            """
        }

        return """
        You are LaunchKit's ChatGPT-authenticated Codex release agent.
        Produce a concise Apple app release plan in plain English.
        Automate deterministic local tasks.
        Mark code mutation, signing, privacy, revenue, public metadata, screenshots, and App Store submission as approval-gated.
        Do not ask for provider API keys.
        Do not propose direct shell execution outside LaunchKit policy gates.

        Project facts:
        \(facts)
        """
    }

    public nonisolated func screenshotDraftPrompt(scan: ProjectScanResult?) -> String {
        let appDescription = scan.map { "\($0.projectType.rawValue) app with \($0.capabilities.count) detected Apple capabilities" }
            ?? "Apple app preparing for App Store release"
        return """
        You are LaunchKit's ChatGPT-authenticated Codex asset director.
        Generate one premium App Store screenshot concept for this app: \(appDescription).
        Return three short labeled lines only:
        Title: ...
        Caption: ...
        Visual Direction: ...
        No markdown, no legal claims, no pricing claims.
        """
    }

    public nonisolated func metadataDraftPrompt(scan: ProjectScanResult?, releasePlan: String?) -> String {
        let projectFacts = scan.map {
            """
            Project type: \($0.projectType.rawValue)
            Capabilities: \($0.capabilities.map(\.rawValue).joined(separator: ", "))
            Findings: \($0.findings.map { "\($0.title): \($0.explanation)" }.joined(separator: "\n"))
            """
        } ?? "No scan selected."
        return """
        You are LaunchKit's ChatGPT-authenticated Codex metadata assistant.
        Draft App Store metadata from local evidence only.
        Return concise sections with labels: Subtitle, Description, Keywords, Release Notes, Review Notes, Privacy Questions.
        Mark assumptions clearly. Do not invent unsupported claims, pricing, awards, or compliance promises.

        Project facts:
        \(projectFacts)

        Current release plan:
        \(releasePlan ?? "No release plan generated yet.")
        """
    }

    public nonisolated func iapDraftPrompt(scan: ProjectScanResult?) -> String {
        let detectedStoreKit = scan?.capabilities.contains(.inAppPurchase) == true
        return """
        You are LaunchKit's ChatGPT-authenticated Codex payments planner.
        Draft a local StoreKit/IAP setup plan for an Apple app.
        Return concise sections with labels: Product Candidates, Subscription Groups, StoreKit Config, Sandbox Testing, Approval Gates.
        Do not choose live prices. Do not propose live App Store Connect mutations without explicit approval.
        StoreKit detected in scan: \(detectedStoreKit ? "yes" : "no")
        """
    }

    private func resolveCodexExecutable() -> String? {
        if let explicitExecutablePath, fileManager.isExecutableFile(atPath: explicitExecutablePath) {
            return explicitExecutablePath
        }
        return resolveExecutable(named: "codex", candidates: [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ])
    }

    private func resolveExecutable(named name: String, candidates: [String]) -> String? {
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in environmentPath.split(separator: ":") {
            let path = "\(directory)/\(name)"
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func runProcessOrFailure(
        executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL?,
        timeout: TimeInterval
    ) async -> CodexCommandResult {
        do {
            return try await runProcess(
                executablePath: executablePath,
                arguments: arguments,
                currentDirectoryURL: currentDirectoryURL,
                timeout: timeout
            )
        } catch {
            return CodexCommandResult(exitCode: -1, standardOutput: "", standardError: error.localizedDescription)
        }
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL?,
        timeout: TimeInterval
    ) async throws -> CodexCommandResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectoryURL
            process.environment = environmentWithDeveloperPaths()

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                process.terminate()
                throw CodexCLIError.timedOut(([executablePath] + arguments).joined(separator: " "))
            }

            let stdoutText = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderrText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return CodexCommandResult(
                exitCode: process.terminationStatus,
                standardOutput: stdoutText,
                standardError: stderrText
            )
        }.value
    }
}

private func environmentWithDeveloperPaths() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let launchKitPath = "/Applications/Codex.app/Contents/Resources:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    let existingPath = environment["PATH"] ?? ""
    environment["PATH"] = existingPath.isEmpty ? launchKitPath : "\(launchKitPath):\(existingPath)"
    environment["TERM"] = environment["TERM"] ?? "xterm-256color"
    return environment
}
