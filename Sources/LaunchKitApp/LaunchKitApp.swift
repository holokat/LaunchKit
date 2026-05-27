import SwiftUI
import LaunchKitAI
import LaunchKitAppStoreConnect
import LaunchKitAssets
import LaunchKitBuild
import LaunchKitCompliance
import LaunchKitCore
import LaunchKitDiff
import LaunchKitExecution
import LaunchKitPayments
import LaunchKitPersistence
import LaunchKitPolicy
import LaunchKitScanner
import LaunchKitSecrets
import LaunchKitSigning

@main
struct LaunchKitApplication: App {
    @State private var model = LaunchKitAppModel()

    var body: some Scene {
        WindowGroup {
            LaunchKitRootView(model: model)
                .frame(minWidth: 1120, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

@Observable
@MainActor
final class LaunchKitAppModel {
    var selectedScreen: LaunchKitScreen = .home
    var scanResult: ProjectScanResult?
    var findings: [DiagnosticFinding] = LaunchKitSampleData.findings
    var plannedActions: [LaunchKitAction] = LaunchKitSampleData.actions
    var events: [WorkflowEvent] = LaunchKitSampleData.events

    private let scanner = FileSystemProjectScanner()

    func scan(path: String) async {
        do {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let result = try await scanner.scan(rootURL: url)
            scanResult = result
            findings = result.findings
            events.insert(WorkflowEvent(
                phase: .scanning,
                title: "Project scan completed",
                detail: "\(result.projectType.rawValue) with \(result.findings.count) findings",
                risk: .informational
            ), at: 0)
            selectedScreen = .scanResults
        } catch {
            findings = [DiagnosticFinding(
                title: "Scan failed",
                explanation: error.localizedDescription,
                severity: .blocker,
                risk: .high
            )]
            selectedScreen = .scanResults
        }
    }
}

enum LaunchKitScreen: String, CaseIterable, Identifiable {
    case home = "Home"
    case scanResults = "Scan Results"
    case releasePlan = "Release Plan"
    case buildMonitor = "Build Monitor"
    case screenshots = "Screenshots"
    case metadata = "Metadata"
    case payments = "IAP"
    case compliance = "Compliance"
    case submission = "Submission"
    case settings = "Settings"

    var id: String { rawValue }
}

struct LaunchKitRootView: View {
    @Bindable var model: LaunchKitAppModel

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $model.selectedScreen)
        } detail: {
            switch model.selectedScreen {
            case .home:
                HomeView(model: model)
            case .scanResults:
                ScanResultsView(result: model.scanResult, findings: model.findings)
            case .releasePlan:
                ReleasePlanView(actions: model.plannedActions)
            case .buildMonitor:
                BuildMonitorView(events: model.events)
            case .screenshots:
                PlaceholderWorkflowView(title: "Screenshot Gallery", phase: .screenshots)
            case .metadata:
                PlaceholderWorkflowView(title: "Metadata Editor", phase: .metadata)
            case .payments:
                PlaceholderWorkflowView(title: "IAP Manager", phase: .payments)
            case .compliance:
                ComplianceView(findings: model.findings)
            case .submission:
                PlaceholderWorkflowView(title: "Final Submission Review", phase: .submission)
            case .settings:
                SettingsView()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct Sidebar: View {
    @Binding var selection: LaunchKitScreen

    var body: some View {
        List(LaunchKitScreen.allCases, selection: $selection) { screen in
            Label(screen.rawValue, systemImage: icon(for: screen))
                .tag(screen)
        }
        .navigationTitle("LaunchKit")
        .listStyle(.sidebar)
    }

    private func icon(for screen: LaunchKitScreen) -> String {
        switch screen {
        case .home: "sparkles"
        case .scanResults: "waveform.path.ecg.rectangle"
        case .releasePlan: "checklist.checked"
        case .buildMonitor: "hammer"
        case .screenshots: "photo.on.rectangle"
        case .metadata: "text.alignleft"
        case .payments: "creditcard"
        case .compliance: "checkmark.seal"
        case .submission: "paperplane"
        case .settings: "key"
        }
    }
}

struct HomeView: View {
    @Bindable var model: LaunchKitAppModel
    @State private var projectPath = FileManager.default.currentDirectoryPath

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HeaderBlock(
                    eyebrow: "AI-powered App Store Release Agent",
                    title: "Ship Apple apps without signing hell.",
                    subtitle: "LaunchKit scans local projects, explains risk in plain English, prepares reversible fixes, and keeps public, legal, and revenue-impacting actions behind review gates."
                )

                HStack(spacing: 16) {
                    TextField("Project path", text: $projectPath)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        Task { await model.scan(path: projectPath) }
                    } label: {
                        Label("Scan Project", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                }

                WorkflowTimeline(events: model.events)
            }
            .padding(32)
        }
    }
}

struct ScanResultsView: View {
    var result: ProjectScanResult?
    var findings: [DiagnosticFinding]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderBlock(
                    eyebrow: result?.projectType.rawValue ?? "No project scanned",
                    title: "Scan Results",
                    subtitle: "Findings are grouped by operational risk. Safe reads can run automatically; changes are routed through policy decisions and rollback checkpoints."
                )

                if let result {
                    HStack(spacing: 12) {
                        MetricPill(title: "Projects", value: "\(result.xcodeProjects.count)")
                        MetricPill(title: "Workspaces", value: "\(result.workspaces.count)")
                        MetricPill(title: "Managers", value: "\(result.packageManagers.count)")
                        MetricPill(title: "Capabilities", value: "\(result.capabilities.count)")
                    }
                }

                FindingList(findings: findings)
            }
            .padding(32)
        }
    }
}

struct ReleasePlanView: View {
    let actions: [LaunchKitAction]
    private let policyEngine = PolicyEngine()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderBlock(
                    eyebrow: "Policy-controlled execution",
                    title: "Release Plan",
                    subtitle: "Each proposed action declares its risk, approval requirement, affected files, and rollback behavior before execution."
                )

                ForEach(actions) { action in
                    let decision = policyEngine.decision(for: action)
                    ActionRow(action: action, decision: decision)
                }
            }
            .padding(32)
        }
    }
}

struct BuildMonitorView: View {
    let events: [WorkflowEvent]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderBlock(
                    eyebrow: "Local build pipeline",
                    title: "Build Monitor",
                    subtitle: "Command output, xcresult summaries, signing diagnostics, and recovery options belong here. Upload and submission remain separate approval-gated actions."
                )
                WorkflowTimeline(events: events)
            }
            .padding(32)
        }
    }
}

struct ComplianceView: View {
    let findings: [DiagnosticFinding]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderBlock(
                    eyebrow: "Preflight audit",
                    title: "App Review Compliance",
                    subtitle: "The auditor maps repo, metadata, purchase, privacy, and runtime evidence to actionable App Review risks before submission."
                )
                FindingList(findings: findings)
            }
            .padding(32)
        }
    }
}

struct PlaceholderWorkflowView: View {
    let title: String
    let phase: WorkflowPhase

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderBlock(
                eyebrow: phase.rawValue,
                title: title,
                subtitle: "This surface is reserved in the native shell. Its actions must use LaunchKit policy gates before they touch public, legal, revenue, or destructive systems."
            )
            Spacer()
        }
        .padding(32)
    }
}

struct SettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderBlock(
                eyebrow: "Local-first secrets",
                title: "Settings & Secrets",
                subtitle: "Provider tokens, App Store Connect API keys, signing material, and repository access must stay in Keychain-backed local storage by default."
            )
            Spacer()
        }
        .padding(32)
    }
}

struct HeaderBlock: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 760, alignment: .leading)
        }
    }
}

struct FindingList: View {
    let findings: [DiagnosticFinding]

    var body: some View {
        VStack(spacing: 12) {
            if findings.isEmpty {
                ContentUnavailableView("No findings", systemImage: "checkmark.seal", description: Text("LaunchKit has not detected release blockers in the current scan."))
            } else {
                ForEach(findings) { finding in
                    FindingRow(finding: finding)
                }
            }
        }
    }
}

struct FindingRow: View {
    let finding: DiagnosticFinding

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                RiskPill(risk: finding.risk)
                SeverityPill(severity: finding.severity)
                Spacer()
            }
            Text(finding.title)
                .font(.headline)
            Text(finding.explanation)
                .foregroundStyle(.secondary)
            if let recommendedFix = finding.recommendedFix {
                Divider()
                Text(recommendedFix)
                    .font(.callout)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ActionRow: View {
    let action: LaunchKitAction
    let decision: PolicyDecision

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                RiskPill(risk: action.risk)
                Text(decision.requirement.rawValue)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.tertiary, in: Capsule())
                Spacer()
                Image(systemName: action.isReversible ? "arrow.uturn.backward.circle" : "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(action.isReversible ? .green : .orange)
            }
            Text(action.title)
                .font(.headline)
            Text(action.explanation)
                .foregroundStyle(.secondary)
            Text(decision.reason)
                .font(.callout)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct WorkflowTimeline: View {
    let events: [WorkflowEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Timeline")
                .font(.headline)
            ForEach(events) { event in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tint)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title)
                            .font(.subheadline.weight(.semibold))
                        Text(event.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    RiskPill(risk: event.risk)
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct MetricPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title2.weight(.semibold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 112, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct RiskPill: View {
    let risk: RiskLevel

    var body: some View {
        Text(risk.rawValue)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch risk {
        case .informational: .secondary
        case .low: .green
        case .medium: .orange
        case .high: .red
        case .critical: .purple
        }
    }
}

struct SeverityPill: View {
    let severity: DiagnosticSeverity

    var body: some View {
        Text(severity.rawValue)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.tertiary, in: Capsule())
    }
}

enum LaunchKitSampleData {
    static let findings: [DiagnosticFinding] = [
        DiagnosticFinding(
            title: "Connect a local Apple app repository",
            explanation: "LaunchKit needs a repository scan before it can prepare a release plan.",
            severity: .info,
            risk: .informational,
            recommendedFix: "Choose a project folder and run the scanner."
        )
    ]

    static let actions: [LaunchKitAction] = [
        LaunchKitAction(
            title: "Scan project files",
            explanation: "Read project manifests, entitlement files, package managers, and privacy manifests.",
            category: .safeRead,
            risk: .informational,
            isReversible: true
        ),
        LaunchKitAction(
            title: "Generate draft privacy manifest",
            explanation: "Create a local PrivacyInfo.xcprivacy draft from detected API usage for human review.",
            category: .safeReversibleWrite,
            risk: .medium,
            affectedPaths: ["PrivacyInfo.xcprivacy"],
            isReversible: true,
            rollbackSummary: "Restore or delete the generated manifest from the checkpoint."
        ),
        LaunchKitAction(
            title: "Create subscription products",
            explanation: "Sync approved subscription definitions to App Store Connect.",
            category: .revenueLegal,
            risk: .critical,
            isReversible: false
        )
    ]

    static let events: [WorkflowEvent] = [
        WorkflowEvent(
            phase: .onboarding,
            title: "LaunchKit initialized",
            detail: "Native shell, policy gates, scanner, and local execution primitives are ready.",
            risk: .informational
        )
    ]
}
