import Foundation
import LaunchKitCore

public enum LocalAgentProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case codex
    case claude

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        }
    }

    public var subscriptionLabel: String {
        switch self {
        case .codex: return "ChatGPT-authenticated Codex"
        case .claude: return "Claude.ai-authenticated Claude Code"
        }
    }

    public var executableName: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        }
    }

    public var npmPackageName: String {
        switch self {
        case .codex: return "@openai/codex"
        case .claude: return "@anthropic-ai/claude-code"
        }
    }

    var defaultExecutablePaths: [String] {
        switch self {
        case .codex:
            return [
                "/Applications/Codex.app/Contents/Resources/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                "/usr/bin/codex"
            ]
        case .claude:
            return [
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
                "/usr/bin/claude"
            ]
        }
    }

    var versionArguments: [String] { ["--version"] }

    var statusArguments: [String] {
        switch self {
        case .codex: return ["login", "status"]
        case .claude: return ["auth", "status"]
        }
    }

    func loginArguments(mode: LocalAgentLoginMode) -> [String] {
        switch (self, mode) {
        case (.codex, .deviceAuth):
            return ["login", "--device-auth"]
        case (.codex, _):
            return ["login"]
        case let (.claude, .email(email)):
            return ["auth", "login", "--email", email]
        case (.claude, .sso):
            return ["auth", "login", "--sso"]
        case (.claude, .console):
            return ["auth", "login", "--console"]
        case (.claude, _):
            return ["auth", "login"]
        }
    }
}

public enum LocalAgentLoginMode: Hashable, Sendable {
    case browser
    case deviceAuth
    case email(String)
    case sso
    case console
}

public enum LocalAgentBridgeError: Error, LocalizedError, Sendable {
    case missingExecutable(LocalAgentProvider)
    case commandFailed(LocalAgentProvider, Int32, String)
    case timedOut(LocalAgentProvider, String)
    case emptyOutput(LocalAgentProvider)

    public var errorDescription: String? {
        switch self {
        case let .missingExecutable(provider):
            return "\(provider.displayName) CLI is not installed."
        case let .commandFailed(provider, status, output):
            return "\(provider.displayName) command failed with exit code \(status): \(output)"
        case let .timedOut(provider, command):
            return "\(provider.displayName) command timed out: \(command)"
        case let .emptyOutput(provider):
            return "\(provider.displayName) did not return output."
        }
    }
}

public struct LocalAgentAuthenticationState: Codable, Hashable, Sendable {
    public var provider: LocalAgentProvider
    public var isInstalled: Bool
    public var isLoggedIn: Bool
    public var executablePath: String?
    public var version: String?
    public var statusText: String

    public init(
        provider: LocalAgentProvider,
        isInstalled: Bool,
        isLoggedIn: Bool,
        executablePath: String?,
        version: String?,
        statusText: String
    ) {
        self.provider = provider
        self.isInstalled = isInstalled
        self.isLoggedIn = isLoggedIn
        self.executablePath = executablePath
        self.version = version
        self.statusText = statusText
    }
}

public struct LocalAgentCommandResult: Codable, Hashable, Sendable {
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

public actor LocalAgentBridge {
    private let explicitExecutablePaths: [LocalAgentProvider: String]
    private let fileManager: FileManager

    public init(
        explicitExecutablePaths: [LocalAgentProvider: String] = [:],
        fileManager: FileManager = .default
    ) {
        self.explicitExecutablePaths = explicitExecutablePaths
        self.fileManager = fileManager
    }

    public func probeAuthentication(provider: LocalAgentProvider) async -> LocalAgentAuthenticationState {
        guard let executablePath = resolveExecutable(for: provider) else {
            return LocalAgentAuthenticationState(
                provider: provider,
                isInstalled: false,
                isLoggedIn: false,
                executablePath: nil,
                version: nil,
                statusText: "\(provider.displayName) CLI is not installed."
            )
        }

        let versionResult = await runProcessOrFailure(
            provider: provider,
            executablePath: executablePath,
            arguments: provider.versionArguments,
            currentDirectoryURL: nil,
            timeout: 20
        )
        let statusResult = await runProcessOrFailure(
            provider: provider,
            executablePath: executablePath,
            arguments: provider.statusArguments,
            currentDirectoryURL: nil,
            timeout: 20
        )

        let version = versionResult.exitCode == 0 ? versionResult.combinedOutput : nil
        return LocalAgentAuthenticationState(
            provider: provider,
            isInstalled: true,
            isLoggedIn: statusResult.exitCode == 0,
            executablePath: executablePath,
            version: version?.isEmpty == false ? version : nil,
            statusText: statusResult.combinedOutput.isEmpty
                ? "\(provider.displayName) auth status unavailable."
                : statusResult.combinedOutput
        )
    }

    public func installWithNPM(provider: LocalAgentProvider) async throws -> LocalAgentAuthenticationState {
        let npm = resolveExecutable(named: "npm", candidates: [
            "/opt/homebrew/bin/npm",
            "/usr/local/bin/npm",
            "/usr/bin/npm"
        ])
        guard let npm else {
            throw LocalAgentBridgeError.commandFailed(provider, -1, "npm is not installed.")
        }

        let result = try await runProcess(
            provider: provider,
            executablePath: npm,
            arguments: ["install", "-g", provider.npmPackageName],
            currentDirectoryURL: nil,
            timeout: 600
        )
        guard result.exitCode == 0 else {
            throw LocalAgentBridgeError.commandFailed(provider, result.exitCode, result.combinedOutput)
        }
        return await probeAuthentication(provider: provider)
    }

    public func login(
        provider: LocalAgentProvider,
        mode: LocalAgentLoginMode = .browser
    ) async throws -> LocalAgentAuthenticationState {
        guard let executablePath = resolveExecutable(for: provider) else {
            throw LocalAgentBridgeError.missingExecutable(provider)
        }

        let result = try await runProcess(
            provider: provider,
            executablePath: executablePath,
            arguments: provider.loginArguments(mode: mode),
            currentDirectoryURL: nil,
            timeout: 900
        )
        guard result.exitCode == 0 else {
            throw LocalAgentBridgeError.commandFailed(provider, result.exitCode, result.combinedOutput)
        }
        return await probeAuthentication(provider: provider)
    }

    public func complete(
        provider: LocalAgentProvider,
        prompt: String,
        workingDirectoryURL: URL?,
        modelOverride: String? = nil,
        timeout: TimeInterval = 900
    ) async throws -> String {
        guard let executablePath = resolveExecutable(for: provider) else {
            throw LocalAgentBridgeError.missingExecutable(provider)
        }

        let outputURL = fileManager.temporaryDirectory
            .appending(path: "launchkit-\(provider.rawValue)-\(UUID().uuidString).txt")
        let arguments = runArguments(
            provider: provider,
            prompt: prompt,
            outputURL: outputURL,
            workingDirectoryURL: workingDirectoryURL,
            modelOverride: modelOverride
        )

        let result = try await runProcess(
            provider: provider,
            executablePath: executablePath,
            arguments: arguments,
            currentDirectoryURL: workingDirectoryURL,
            timeout: timeout
        )
        guard result.exitCode == 0 else {
            throw LocalAgentBridgeError.commandFailed(provider, result.exitCode, result.combinedOutput)
        }

        let fileOutput = (try? String(contentsOf: outputURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try? fileManager.removeItem(at: outputURL)

        let output = fileOutput?.isEmpty == false
            ? fileOutput!
            : result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw LocalAgentBridgeError.emptyOutput(provider) }
        return output
    }

    public nonisolated func releasePlanPrompt(provider: LocalAgentProvider, scan: ProjectScanResult?) -> String {
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
        You are LaunchKit's \(provider.subscriptionLabel) release agent.
        Produce a concise Apple app release plan in plain English.
        Automate deterministic local tasks.
        Mark code mutation, signing, privacy, revenue, public metadata, screenshots, and App Store submission as approval-gated.
        Do not ask for provider API keys.
        Do not propose direct shell execution outside LaunchKit policy gates.

        Project facts:
        \(facts)
        """
    }

    public nonisolated func screenshotDraftPrompt(provider: LocalAgentProvider, scan: ProjectScanResult?) -> String {
        let appDescription = scan.map { "\($0.projectType.rawValue) app with \($0.capabilities.count) detected Apple capabilities" }
            ?? "Apple app preparing for App Store release"
        return """
        You are LaunchKit's \(provider.subscriptionLabel) asset director.
        Generate one premium App Store screenshot concept for this app: \(appDescription).
        Return three short labeled lines only:
        Title: ...
        Caption: ...
        Visual Direction: ...
        No markdown, no legal claims, no pricing claims.
        """
    }

    public nonisolated func metadataDraftPrompt(
        provider: LocalAgentProvider,
        scan: ProjectScanResult?,
        releasePlan: String?
    ) -> String {
        let projectFacts = scan.map {
            """
            Project type: \($0.projectType.rawValue)
            Capabilities: \($0.capabilities.map(\.rawValue).joined(separator: ", "))
            Findings: \($0.findings.map { "\($0.title): \($0.explanation)" }.joined(separator: "\n"))
            """
        } ?? "No scan selected."
        return """
        You are LaunchKit's \(provider.subscriptionLabel) metadata assistant.
        Draft App Store metadata from local evidence only.
        Return only editable field labels and values: Subtitle, Promotional Text, Description, Keywords, Release Notes, Review Notes, Privacy Questions.
        Do not use markdown headings, bullets, analysis, or implementation notes.
        Mark assumptions clearly. Do not invent unsupported claims, pricing, awards, or compliance promises.

        Project facts:
        \(projectFacts)

        Current release plan:
        \(releasePlan ?? "No release plan generated yet.")
        """
    }

    public nonisolated func iapDraftPrompt(provider: LocalAgentProvider, scan: ProjectScanResult?) -> String {
        let detectedStoreKit = scan?.capabilities.contains(.inAppPurchase) == true
        return """
        You are LaunchKit's \(provider.subscriptionLabel) payments planner.
        Draft a local StoreKit/IAP setup plan for an Apple app.
        Return only concise field values:
        Use IAP: yes/no
        Setup Note: one short sentence
        Product: product_id | display name | subscription/one-time/consumable | review note
        Do not use markdown headings, bullets, long explanations, or implementation checklists.
        Do not choose live prices. Do not propose live App Store Connect mutations without explicit approval.
        StoreKit detected in scan: \(detectedStoreKit ? "yes" : "no")
        """
    }

    private func runArguments(
        provider: LocalAgentProvider,
        prompt: String,
        outputURL: URL,
        workingDirectoryURL: URL?,
        modelOverride: String?
    ) -> [String] {
        switch provider {
        case .codex:
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
            return arguments
        case .claude:
            return ["-p", prompt]
        }
    }

    private func resolveExecutable(for provider: LocalAgentProvider) -> String? {
        if let explicitPath = explicitExecutablePaths[provider],
           fileManager.isExecutableFile(atPath: explicitPath) {
            return explicitPath
        }
        return resolveExecutable(
            named: provider.executableName,
            candidates: provider.defaultExecutablePaths
        )
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
        provider: LocalAgentProvider,
        executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL?,
        timeout: TimeInterval
    ) async -> LocalAgentCommandResult {
        do {
            return try await runProcess(
                provider: provider,
                executablePath: executablePath,
                arguments: arguments,
                currentDirectoryURL: currentDirectoryURL,
                timeout: timeout
            )
        } catch {
            return LocalAgentCommandResult(exitCode: -1, standardOutput: "", standardError: error.localizedDescription)
        }
    }

    private func runProcess(
        provider: LocalAgentProvider,
        executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL?,
        timeout: TimeInterval
    ) async throws -> LocalAgentCommandResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectoryURL
            process.environment = environmentWithLocalAgentPaths()

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
                throw LocalAgentBridgeError.timedOut(provider, ([executablePath] + arguments).joined(separator: " "))
            }

            let stdoutText = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderrText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return LocalAgentCommandResult(
                exitCode: process.terminationStatus,
                standardOutput: stdoutText,
                standardError: stderrText
            )
        }.value
    }
}

private func environmentWithLocalAgentPaths() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let launchKitPath = "/Applications/Codex.app/Contents/Resources:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    let existingPath = environment["PATH"] ?? ""
    environment["PATH"] = existingPath.isEmpty ? launchKitPath : "\(launchKitPath):\(existingPath)"
    environment["TERM"] = environment["TERM"] ?? "xterm-256color"
    return environment
}
