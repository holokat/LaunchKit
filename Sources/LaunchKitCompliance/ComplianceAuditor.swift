import Foundation
import LaunchKitCore

public enum AppReviewGuideline: String, Codable, CaseIterable, Sendable {
    case appCompleteness = "2.1"
    case accurateMetadata = "2.3"
    case softwareRequirements = "2.5"
    case payments = "3.1"
    case socialLogin = "4.8"
    case applePayRecurring = "4.9"
    case privacyCollection = "5.1.1"
    case tracking = "5.1.2"
}

public struct ComplianceEvidence: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var source: String
    public var summary: String
    public var confidence: Double

    public init(id: UUID = UUID(), source: String, summary: String, confidence: Double) {
        self.id = id
        self.source = source
        self.summary = summary
        self.confidence = confidence
    }
}

public struct ComplianceRule: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var guideline: AppReviewGuideline
    public var title: String
    public var rationale: String
    public var severity: DiagnosticSeverity

    public init(
        id: String,
        guideline: AppReviewGuideline,
        title: String,
        rationale: String,
        severity: DiagnosticSeverity
    ) {
        self.id = id
        self.guideline = guideline
        self.title = title
        self.rationale = rationale
        self.severity = severity
    }
}

public struct ComplianceFinding: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var rule: ComplianceRule
    public var evidence: [ComplianceEvidence]
    public var diagnostic: DiagnosticFinding

    public init(id: UUID = UUID(), rule: ComplianceRule, evidence: [ComplianceEvidence], diagnostic: DiagnosticFinding) {
        self.id = id
        self.rule = rule
        self.evidence = evidence
        self.diagnostic = diagnostic
    }
}

public struct GuidelineRuleCatalog: Sendable {
    public init() {}

    public var baselineRules: [ComplianceRule] {
        [
            ComplianceRule(
                id: "restore-purchases-required",
                guideline: .payments,
                title: "Restorable purchases need restore UX",
                rationale: "Apps offering restorable digital purchases should provide a clear restore path.",
                severity: .error
            ),
            ComplianceRule(
                id: "account-deletion-required",
                guideline: .privacyCollection,
                title: "Account creation requires deletion",
                rationale: "Apps that allow account creation need an in-app account deletion path.",
                severity: .error
            ),
            ComplianceRule(
                id: "privacy-manifest-required",
                guideline: .privacyCollection,
                title: "Privacy evidence needs review",
                rationale: "Privacy declarations are developer-attested and should be checked against code and SDK evidence.",
                severity: .warning
            ),
            ComplianceRule(
                id: "metadata-must-match-app",
                guideline: .accurateMetadata,
                title: "Metadata must match shipped behavior",
                rationale: "Screenshots, descriptions, claims, and pricing language must represent the actual app.",
                severity: .warning
            )
        ]
    }
}

public struct ComplianceAuditor: Sendable {
    private let catalog: GuidelineRuleCatalog

    public init(catalog: GuidelineRuleCatalog = GuidelineRuleCatalog()) {
        self.catalog = catalog
    }

    public func audit(scan: ProjectScanResult) -> [ComplianceFinding] {
        var findings: [ComplianceFinding] = []

        if scan.capabilities.contains(.inAppPurchase) {
            findings.append(makeFinding(
                ruleID: "restore-purchases-required",
                evidence: ComplianceEvidence(
                    source: "project scan",
                    summary: "In-app purchase capability or StoreKit usage was detected.",
                    confidence: 0.82
                ),
                diagnostic: DiagnosticFinding(
                    title: "Verify restore purchases",
                    explanation: "LaunchKit detected purchase support. Restorable products and subscriptions need an obvious restore path before App Review.",
                    severity: .warning,
                    risk: .high,
                    recommendedFix: "Run the purchase flow audit and confirm restore UX is visible on paywalls or account screens.",
                    appleReference: AppReviewGuideline.payments.rawValue
                )
            ))
        }

        if !scan.rootURL.path.isEmpty && !scan.findings.contains(where: { $0.title == "Privacy manifest not found" }) {
            findings.append(makeFinding(
                ruleID: "privacy-manifest-required",
                evidence: ComplianceEvidence(
                    source: "project scan",
                    summary: "Privacy manifest evidence is present; user-attested privacy answers still need review.",
                    confidence: 0.65
                ),
                diagnostic: DiagnosticFinding(
                    title: "Review privacy disclosures",
                    explanation: "Privacy manifests and App Store privacy answers are legal disclosures. LaunchKit can cross-check evidence, but the developer must approve the final answers.",
                    severity: .info,
                    risk: .medium,
                    appleReference: AppReviewGuideline.privacyCollection.rawValue
                )
            ))
        }

        return findings
    }

    private func makeFinding(
        ruleID: String,
        evidence: ComplianceEvidence,
        diagnostic: DiagnosticFinding
    ) -> ComplianceFinding {
        let rule = catalog.baselineRules.first { $0.id == ruleID }
            ?? ComplianceRule(id: ruleID, guideline: .appCompleteness, title: diagnostic.title, rationale: diagnostic.explanation, severity: diagnostic.severity)
        return ComplianceFinding(rule: rule, evidence: [evidence], diagnostic: diagnostic)
    }
}

