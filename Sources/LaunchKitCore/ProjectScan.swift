import Foundation

public struct ProjectScanResult: Codable, Hashable, Sendable {
    public var rootURL: URL
    public var detectedAt: Date
    public var projectType: ProjectType
    public var appContext: ProjectAppContext
    public var xcodeProjects: [DiscoveredFile]
    public var workspaces: [DiscoveredFile]
    public var packageManagers: [PackageManager]
    public var targets: [DiscoveredTarget]
    public var capabilities: [DetectedCapability]
    public var findings: [DiagnosticFinding]

    public init(
        rootURL: URL,
        detectedAt: Date = Date(),
        projectType: ProjectType,
        appContext: ProjectAppContext = ProjectAppContext(),
        xcodeProjects: [DiscoveredFile] = [],
        workspaces: [DiscoveredFile] = [],
        packageManagers: [PackageManager] = [],
        targets: [DiscoveredTarget] = [],
        capabilities: [DetectedCapability] = [],
        findings: [DiagnosticFinding] = []
    ) {
        self.rootURL = rootURL
        self.detectedAt = detectedAt
        self.projectType = projectType
        self.appContext = appContext
        self.xcodeProjects = xcodeProjects
        self.workspaces = workspaces
        self.packageManagers = packageManagers
        self.targets = targets
        self.capabilities = capabilities
        self.findings = findings
    }
}

public struct ProjectAppContext: Codable, Hashable, Sendable {
    public var displayNameCandidates: [String]
    public var bundleIdentifiers: [String]
    public var descriptions: [String]
    public var readmeExcerpts: [String]
    public var manifestSignals: [String]
    public var sourceStrings: [String]

    public init(
        displayNameCandidates: [String] = [],
        bundleIdentifiers: [String] = [],
        descriptions: [String] = [],
        readmeExcerpts: [String] = [],
        manifestSignals: [String] = [],
        sourceStrings: [String] = []
    ) {
        self.displayNameCandidates = displayNameCandidates
        self.bundleIdentifiers = bundleIdentifiers
        self.descriptions = descriptions
        self.readmeExcerpts = readmeExcerpts
        self.manifestSignals = manifestSignals
        self.sourceStrings = sourceStrings
    }

    public var preferredDisplayName: String? {
        displayNameCandidates.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public var preferredDescription: String? {
        descriptions.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? readmeExcerpts.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public var promptSummary: String {
        var sections: [String] = []
        if !displayNameCandidates.isEmpty {
            sections.append("Name candidates: \(displayNameCandidates.prefix(6).joined(separator: ", "))")
        }
        if !bundleIdentifiers.isEmpty {
            sections.append("Bundle identifiers: \(bundleIdentifiers.prefix(6).joined(separator: ", "))")
        }
        if !descriptions.isEmpty {
            sections.append("Description signals:\n\(descriptions.prefix(4).map { "- \($0)" }.joined(separator: "\n"))")
        }
        if !readmeExcerpts.isEmpty {
            sections.append("README excerpts:\n\(readmeExcerpts.prefix(3).map { "- \($0)" }.joined(separator: "\n"))")
        }
        if !manifestSignals.isEmpty {
            sections.append("Manifest signals:\n\(manifestSignals.prefix(8).map { "- \($0)" }.joined(separator: "\n"))")
        }
        if !sourceStrings.isEmpty {
            sections.append("Visible app strings:\n\(sourceStrings.prefix(16).map { "- \($0)" }.joined(separator: "\n"))")
        }
        return sections.isEmpty ? "No app-specific product context was extracted." : sections.joined(separator: "\n\n")
    }
}

public enum ProjectType: String, Codable, CaseIterable, Sendable {
    case nativeXcode
    case swiftPackage
    case reactNative
    case flutter
    case capacitor
    case tuist
    case xcodegen
    case unknown
}

public enum PackageManager: String, Codable, CaseIterable, Sendable {
    case swiftPackageManager
    case cocoaPods
    case carthage
    case tuist
    case xcodegen
    case npm
    case yarn
    case pnpm
    case flutter
}

public struct DiscoveredFile: Codable, Hashable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var kind: String

    public init(path: String, kind: String) {
        self.path = path
        self.kind = kind
    }
}

public struct DiscoveredTarget: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(name)-\(bundleIdentifier ?? "unknown")" }
    public var name: String
    public var bundleIdentifier: String?
    public var platform: ApplePlatform?
    public var deploymentTarget: String?

    public init(
        name: String,
        bundleIdentifier: String? = nil,
        platform: ApplePlatform? = nil,
        deploymentTarget: String? = nil
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.platform = platform
        self.deploymentTarget = deploymentTarget
    }
}

public enum DetectedCapability: String, Codable, CaseIterable, Sendable {
    case pushNotifications
    case associatedDomains
    case iCloud
    case healthKit
    case inAppPurchase
    case appTrackingTransparency
    case camera
    case microphone
    case location
    case bluetooth
    case keychainSharing
    case signInWithApple
}
