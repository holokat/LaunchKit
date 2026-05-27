import Foundation

public struct AppleDeveloperEnvironment: Codable, Hashable, Sendable {
    public var xcodeVersion: String?
    public var codeSigningIdentityCount: Int
    public var transporterAvailable: Bool
    public var diagnostics: [String]

    public init(
        xcodeVersion: String?,
        codeSigningIdentityCount: Int,
        transporterAvailable: Bool,
        diagnostics: [String]
    ) {
        self.xcodeVersion = xcodeVersion
        self.codeSigningIdentityCount = codeSigningIdentityCount
        self.transporterAvailable = transporterAvailable
        self.diagnostics = diagnostics
    }

    public var isUsable: Bool {
        xcodeVersion != nil
    }
}

public struct AppleDeveloperEnvironmentProbe: Sendable {
    public init() {}

    public func probe() async -> AppleDeveloperEnvironment {
        async let xcode = run("/usr/bin/xcodebuild", ["-version"])
        async let identities = run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        async let transporter = run("/usr/bin/xcrun", ["-f", "iTMSTransporter"])

        let xcodeResult = await xcode
        let identityResult = await identities
        let transporterResult = await transporter

        let identityCount = identityResult.output
            .split(separator: "\n")
            .filter { $0.contains("\"") && !$0.localizedCaseInsensitiveContains("valid identities found") }
            .count

        var diagnostics: [String] = []
        if xcodeResult.exitCode != 0 {
            diagnostics.append("Xcode command line tools are not available.")
        }
        if identityCount == 0 {
            diagnostics.append("No local code-signing identities were found.")
        }
        if transporterResult.exitCode != 0 {
            diagnostics.append("Transporter was not found through xcrun.")
        }

        return AppleDeveloperEnvironment(
            xcodeVersion: xcodeResult.exitCode == 0 ? xcodeResult.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            codeSigningIdentityCount: identityCount,
            transporterAvailable: transporterResult.exitCode == 0,
            diagnostics: diagnostics
        )
    }

    private func run(_ executable: String, _ arguments: [String]) async -> ProbeCommandResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return ProbeCommandResult(exitCode: -1, output: error.localizedDescription)
            }

            let outputText = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let errorText = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return ProbeCommandResult(exitCode: process.terminationStatus, output: outputText + errorText)
        }.value
    }
}

private struct ProbeCommandResult: Sendable {
    var exitCode: Int32
    var output: String
}

