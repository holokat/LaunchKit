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
    var discoveredProjects: [DiscoveredProjectCandidate] = []
    var isDiscoveringProjects = false
    var aiConnectionState: ConnectionState = .notConnected
    var appleConnectionState: ConnectionState = .notConnected

    private let scanner = FileSystemProjectScanner()
    private let discoveryService = ProjectDiscoveryService()

    func connectAI() {
        aiConnectionState = .needsImplementation
        events.insert(WorkflowEvent(
            phase: .onboarding,
            title: "AI connection needs provider wiring",
            detail: "The production app should open Codex/Claude provider auth first, then store the local credential reference in Keychain.",
            risk: .medium
        ), at: 0)
    }

    func connectApple() {
        appleConnectionState = .needsImplementation
        events.insert(WorkflowEvent(
            phase: .onboarding,
            title: "Apple connection needs guided setup",
            detail: "LaunchKit should prefer a guided Apple connection and keep API-key import as the advanced fallback for API-only automation.",
            risk: .medium
        ), at: 0)
    }

    func discoverProjects() async {
        isDiscoveringProjects = true
        let projects = await discoveryService.discover()
        discoveredProjects = projects
        isDiscoveringProjects = false
        events.insert(WorkflowEvent(
            phase: .scanning,
            title: "Project discovery completed",
            detail: projects.isEmpty ? "No Apple projects found in common developer folders." : "Found \(projects.count) candidate projects.",
            risk: .informational
        ), at: 0)
    }

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

enum ConnectionState: String {
    case notConnected = "Not connected"
    case connected = "Connected"
    case needsImplementation = "Needs implementation"
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HeaderBlock(
                    eyebrow: "Release cockpit",
                    title: "Connect AI. Find your apps. Ship with review gates.",
                    subtitle: "LaunchKit should discover local Apple projects automatically, let AI generate the release plan and assets, and ask for approval only when a step affects code, Apple state, public metadata, privacy, or revenue."
                )

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                    OnboardingStepCard(
                        number: "1",
                        title: "Connect Codex or Claude",
                        status: model.aiConnectionState.rawValue,
                        bodyText: "The release agent needs an AI provider before it can explain findings, generate fixes, draft metadata, and regenerate screenshots or icons.",
                        buttonTitle: "Connect AI",
                        systemImage: "sparkles"
                    ) {
                        model.connectAI()
                    }

                    OnboardingStepCard(
                        number: "2",
                        title: "Find projects automatically",
                        status: model.isDiscoveringProjects ? "Searching" : "\(model.discoveredProjects.count) found",
                        bodyText: "LaunchKit looks in common developer folders for Xcode, SwiftPM, React Native, Flutter, Capacitor, Tuist, and XcodeGen projects.",
                        buttonTitle: model.isDiscoveringProjects ? "Searching..." : "Find Projects",
                        systemImage: "folder.badge.gearshape"
                    ) {
                        Task { await model.discoverProjects() }
                    }

                    OnboardingStepCard(
                        number: "3",
                        title: "Connect Apple",
                        status: model.appleConnectionState.rawValue,
                        bodyText: "Use the easiest Apple connection available, then fall back to App Store Connect API keys only when Apple requires API-only automation.",
                        buttonTitle: "Connect Apple",
                        systemImage: "apple.logo"
                    ) {
                        model.connectApple()
                    }
                }

                if !model.discoveredProjects.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Detected Projects")
                            .font(.headline)
                        ForEach(model.discoveredProjects) { project in
                            DiscoveredProjectRow(project: project) {
                                Task { await model.scan(path: project.rootURL.path) }
                            }
                        }
                    }
                }

                AutomationPreview()

                WorkflowTimeline(events: model.events)
            }
            .padding(32)
        }
    }
}

struct OnboardingStepCard: View {
    let number: String
    let title: String
    let status: String
    let bodyText: String
    let buttonTitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(number)
                    .font(.caption.weight(.bold))
                    .frame(width: 24, height: 24)
                    .background(.tint.opacity(0.16), in: Circle())
                Text(status)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.tertiary, in: Capsule())
                Spacer()
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.headline)
            Text(bodyText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: action) {
                Label(buttonTitle, systemImage: systemImage)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct DiscoveredProjectRow: View {
    let project: DiscoveredProjectCandidate
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.subheadline.weight(.semibold))
                Text(project.rootURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(project.projectType.rawValue)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.tertiary, in: Capsule())
            Button("Open Release") {
                action()
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct AutomationPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI-Generated Release Flow")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                FlowChip(title: "Scan and explain", icon: "text.magnifyingglass")
                FlowChip(title: "Auto-fix safe issues", icon: "wand.and.sparkles")
                FlowChip(title: "Regenerate screenshots", icon: "photo.stack")
                FlowChip(title: "Draft metadata", icon: "doc.text")
                FlowChip(title: "Prepare IAPs", icon: "creditcard")
                FlowChip(title: "Submit after approval", icon: "paperplane")
            }
        }
    }
}

struct FlowChip: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title)
                .font(.callout.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            subtitle: "Provider credentials, Apple connection state, signing material, and repository access must stay in Keychain-backed local storage by default. API-key import should be an advanced fallback, not the first thing users see."
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
