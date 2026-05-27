import Foundation

public struct ProjectScanResult: Codable, Hashable, Sendable {
    public var rootURL: URL
    public var detectedAt: Date
    public var projectType: ProjectType
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
        self.xcodeProjects = xcodeProjects
        self.workspaces = workspaces
        self.packageManagers = packageManagers
        self.targets = targets
        self.capabilities = capabilities
        self.findings = findings
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

