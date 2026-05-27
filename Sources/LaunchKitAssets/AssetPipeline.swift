import Foundation
import LaunchKitCore

public enum AssetApprovalState: String, Codable, CaseIterable, Sendable {
    case draft
    case generated
    case edited
    case approved
    case uploaded
    case rejected
}

public enum ScreenshotCaptureSource: String, Codable, CaseIterable, Sendable {
    case xcuITestAttachment
    case simctlScreenshot
    case manualImport
}

public struct ScreenshotArtifact: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var locale: String
    public var displayTarget: String
    public var source: ScreenshotCaptureSource
    public var localPath: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var state: AssetApprovalState
    public var recipeHash: String?

    public init(
        id: UUID = UUID(),
        locale: String,
        displayTarget: String,
        source: ScreenshotCaptureSource,
        localPath: String,
        pixelWidth: Int,
        pixelHeight: Int,
        state: AssetApprovalState = .draft,
        recipeHash: String? = nil
    ) {
        self.id = id
        self.locale = locale
        self.displayTarget = displayTarget
        self.source = source
        self.localPath = localPath
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.state = state
        self.recipeHash = recipeHash
    }
}

public struct ScreenshotRequirement: Codable, Hashable, Sendable {
    public var displayTarget: String
    public var minimumCount: Int
    public var maximumCount: Int
    public var acceptedFormats: [String]

    public init(
        displayTarget: String,
        minimumCount: Int = 1,
        maximumCount: Int = 10,
        acceptedFormats: [String] = ["png", "jpg", "jpeg"]
    ) {
        self.displayTarget = displayTarget
        self.minimumCount = minimumCount
        self.maximumCount = maximumCount
        self.acceptedFormats = acceptedFormats
    }
}

public struct AssetPipelinePlanner: Sendable {
    public init() {}

    public func validate(_ artifacts: [ScreenshotArtifact], against requirement: ScreenshotRequirement) -> [DiagnosticFinding] {
        let matching = artifacts.filter { $0.displayTarget == requirement.displayTarget }
        var findings: [DiagnosticFinding] = []

        if matching.count < requirement.minimumCount {
            findings.append(DiagnosticFinding(
                title: "Screenshot set is incomplete",
                explanation: "\(requirement.displayTarget) needs at least \(requirement.minimumCount) approved screenshot before upload.",
                severity: .blocker,
                risk: .high,
                recommendedFix: "Capture or import screenshots for this display target."
            ))
        }

        if matching.count > requirement.maximumCount {
            findings.append(DiagnosticFinding(
                title: "Screenshot set has too many images",
                explanation: "\(requirement.displayTarget) has \(matching.count) screenshots, but App Store Connect accepts at most \(requirement.maximumCount) per set.",
                severity: .error,
                risk: .medium,
                recommendedFix: "Remove or split the extra screenshots before upload."
            ))
        }

        if matching.contains(where: { $0.state != .approved && $0.state != .uploaded }) {
            findings.append(DiagnosticFinding(
                title: "Screenshot upload needs approval",
                explanation: "Generated or edited screenshots are public-facing assets and must be approved before upload.",
                severity: .warning,
                risk: .high,
                recommendedFix: "Review the gallery, captions, and device frames, then approve the final set."
            ))
        }

        return findings
    }

    public func uploadAction(paths: [String]) -> LaunchKitAction {
        LaunchKitAction(
            title: "Upload screenshots to App Store Connect",
            explanation: "Upload approved public screenshots for the selected locale and display target.",
            category: .publicFacing,
            risk: .high,
            affectedPaths: paths,
            isReversible: false,
            rollbackSummary: "Remote rollback depends on the app version state; LaunchKit snapshots previous screenshot IDs before upload."
        )
    }
}

