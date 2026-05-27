import Foundation
import LaunchKitCore
import LaunchKitPolicy

public protocol ProjectScanning: Sendable {
    func scan(rootURL: URL) async throws -> ProjectScanResult
}

public struct FileSystemProjectScanner: ProjectScanning {
    public init() {}

    public func scan(rootURL: URL) async throws -> ProjectScanResult {
        try await Task.detached(priority: .utility) {
            let index = try ProjectFileIndex(rootURL: rootURL)
            let projectType = detectProjectType(index)
            let packageManagers = detectPackageManagers(index)
            let capabilities = detectCapabilities(index)
            var findings = detectFindings(index: index, projectType: projectType, capabilities: capabilities)

            if projectType == .unknown {
                findings.append(DiagnosticFinding(
                    title: "No Apple project was detected",
                    explanation: "LaunchKit could not find an Xcode project, workspace, Swift package, Tuist manifest, XcodeGen manifest, Flutter project, React Native project, or Capacitor project in this folder.",
                    severity: .blocker,
                    risk: .medium,
                    affectedPaths: [rootURL.path],
                    recommendedFix: "Select the repository root that contains your Apple app project."
                ))
            }

            return ProjectScanResult(
                rootURL: rootURL,
                projectType: projectType,
                xcodeProjects: index.files(withSuffix: ".xcodeproj").map { DiscoveredFile(path: $0, kind: "Xcode project") },
                workspaces: index.files(withSuffix: ".xcworkspace").map { DiscoveredFile(path: $0, kind: "Xcode workspace") },
                packageManagers: packageManagers,
                capabilities: capabilities,
                findings: findings
            )
        }.value
    }
}

private struct ProjectFileIndex: Sendable {
    let rootURL: URL
    let relativePaths: [String]
    let basenames: Set<String>

    init(rootURL: URL) throws {
        self.rootURL = rootURL
        let fileManager = FileManager.default
        var paths: [String] = []

        func walk(_ directoryURL: URL) throws {
            let children = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for child in children {
                let relativePath = child.path.replacingOccurrences(of: rootURL.path + "/", with: "")
                let basename = child.lastPathComponent
                paths.append(relativePath)

                guard shouldDescend(into: child, basename: basename) else { continue }

                let values = try child.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == true {
                    try walk(child)
                }
            }
        }

        try walk(rootURL)
        for manifest in knownRootManifests {
            let manifestURL = rootURL.appending(path: manifest)
            if fileManager.fileExists(atPath: manifestURL.path) && !paths.contains(manifest) {
                paths.append(manifest)
            }
        }

        self.relativePaths = paths.sorted()
        self.basenames = Set(paths.map { URL(fileURLWithPath: $0).lastPathComponent })
    }

    func containsBasename(_ name: String) -> Bool {
        basenames.contains(name)
    }

    func containsPathSuffix(_ suffix: String) -> Bool {
        relativePaths.contains { $0.hasSuffix(suffix) }
    }

    func files(withSuffix suffix: String) -> [String] {
        relativePaths.filter { $0.hasSuffix(suffix) }
    }
}

private func shouldDescend(into url: URL, basename: String) -> Bool {
    if basename == ".git" || basename == ".build" || basename == "DerivedData" {
        return false
    }
    if url.pathExtension == "xcodeproj" || url.pathExtension == "xcworkspace" {
        return false
    }
    return true
}

private let knownRootManifests = [
    "Package.swift",
    "Podfile",
    "Cartfile",
    "Project.swift",
    "Workspace.swift",
    "project.yml",
    "project.yaml",
    "pubspec.yaml",
    "package.json",
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "capacitor.config.ts",
    "capacitor.config.json"
]

private func detectProjectType(_ index: ProjectFileIndex) -> ProjectType {
    if index.containsBasename("Package.swift") { return .swiftPackage }
    if index.containsBasename("Project.swift") { return .tuist }
    if index.containsBasename("project.yml") || index.containsBasename("project.yaml") { return .xcodegen }
    if index.containsBasename("pubspec.yaml") { return .flutter }
    if index.containsBasename("capacitor.config.ts") || index.containsBasename("capacitor.config.json") { return .capacitor }
    if index.containsBasename("package.json") && index.containsPathSuffix("ios") { return .reactNative }
    if !index.files(withSuffix: ".xcodeproj").isEmpty || !index.files(withSuffix: ".xcworkspace").isEmpty { return .nativeXcode }
    return .unknown
}

private func detectPackageManagers(_ index: ProjectFileIndex) -> [PackageManager] {
    var managers: [PackageManager] = []
    if index.containsBasename("Package.swift") { managers.append(.swiftPackageManager) }
    if index.containsBasename("Podfile") { managers.append(.cocoaPods) }
    if index.containsBasename("Cartfile") { managers.append(.carthage) }
    if index.containsBasename("Project.swift") { managers.append(.tuist) }
    if index.containsBasename("project.yml") || index.containsBasename("project.yaml") { managers.append(.xcodegen) }
    if index.containsBasename("package-lock.json") { managers.append(.npm) }
    if index.containsBasename("yarn.lock") { managers.append(.yarn) }
    if index.containsBasename("pnpm-lock.yaml") { managers.append(.pnpm) }
    if index.containsBasename("pubspec.yaml") { managers.append(.flutter) }
    return managers
}

private func detectCapabilities(_ index: ProjectFileIndex) -> [DetectedCapability] {
    var capabilities = Set<DetectedCapability>()

    for path in index.relativePaths {
        let lowercased = path.lowercased()
        if lowercased.hasSuffix(".storekit") { capabilities.insert(.inAppPurchase) }
        if lowercased.hasSuffix(".entitlements") {
            let absoluteURL = index.rootURL.appending(path: path)
            if let contents = try? String(contentsOf: absoluteURL, encoding: .utf8) {
                if contents.contains("aps-environment") { capabilities.insert(.pushNotifications) }
                if contents.contains("com.apple.developer.associated-domains") { capabilities.insert(.associatedDomains) }
                if contents.contains("com.apple.developer.icloud") { capabilities.insert(.iCloud) }
                if contents.contains("com.apple.developer.healthkit") { capabilities.insert(.healthKit) }
                if contents.contains("keychain-access-groups") { capabilities.insert(.keychainSharing) }
            }
        }
        if lowercased.contains("revenuecat") { capabilities.insert(.inAppPurchase) }
        if lowercased.contains("apptrackingtransparency") { capabilities.insert(.appTrackingTransparency) }
    }

    return capabilities.sorted { $0.rawValue < $1.rawValue }
}

private func detectFindings(
    index: ProjectFileIndex,
    projectType: ProjectType,
    capabilities: [DetectedCapability]
) -> [DiagnosticFinding] {
    var findings: [DiagnosticFinding] = []

    if projectType == .swiftPackage && index.files(withSuffix: ".xcodeproj").isEmpty {
        findings.append(DiagnosticFinding(
            title: "Swift package detected without an app project",
            explanation: "This folder builds as a Swift package. To ship through App Store Connect, LaunchKit will need an app target or generated Xcode project before archive and upload.",
            severity: .warning,
            risk: .medium,
            affectedPaths: ["Package.swift"],
            recommendedFix: "Create or select the app target that produces the signed archive."
        ))
    }

    if capabilities.contains(.inAppPurchase) && !index.containsBasename("StoreKitConfig.storekit") {
        findings.append(DiagnosticFinding(
            title: "In-app purchases need a local test configuration",
            explanation: "Purchase code or StoreKit assets were detected, but no standard StoreKit configuration file was found for deterministic local testing.",
            severity: .warning,
            risk: .medium,
            recommendedFix: "Generate a StoreKit configuration file and review products before syncing live App Store Connect changes."
        ))
    }

    if !index.relativePaths.contains(where: { $0.hasSuffix("PrivacyInfo.xcprivacy") }) {
        findings.append(DiagnosticFinding(
            title: "Privacy manifest not found",
            explanation: "Apple requires privacy manifests for many apps and SDKs. LaunchKit did not find a PrivacyInfo.xcprivacy file in this project scan.",
            severity: .warning,
            risk: .medium,
            recommendedFix: "Generate a draft privacy manifest from detected APIs and review it before committing."
        ))
    }

    return findings
}
