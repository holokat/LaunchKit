import AppKit
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
    var isCheckingCodex = false
    var isInstallingCodex = false
    var isLoggingIntoCodex = false
    var isGeneratingReleasePlan = false
    var isGeneratingScreenshotDraft = false
    var isGeneratingMetadataDraft = false
    var isGeneratingIAPDraft = false
    var isConnectingApple = false
    var aiConnectionState: ConnectionState = .notConnected
    var appleConnectionState: ConnectionState = .notConnected
    var codexAuthenticationState: CodexAuthenticationState?
    var codexStatusMessage = "Codex status has not been checked yet."
    var appleEnvironment: AppleDeveloperEnvironment?
    var appleConnectionMessage = "Apple developer environment has not been checked yet."
    var generatedReleasePlan: String?
    var generatedScreenshotDraft: GeneratedScreenshotDraft?
    var generatedMetadataDraft: String?
    var generatedIAPDraft: String?

    private let scanner = FileSystemProjectScanner()
    private let discoveryService = ProjectDiscoveryService()
    private let codexClient = CodexCLIClient()
    private let appleProbe = AppleDeveloperEnvironmentProbe()

    func refreshCodexStatus() async {
        isCheckingCodex = true
        let state = await codexClient.probeAuthentication()
        applyCodexState(state)
        isCheckingCodex = false
    }

    func installCodex() async {
        isInstallingCodex = true
        aiConnectionState = .installing
        do {
            let state = try await codexClient.installWithNPM()
            applyCodexState(state)
            events.insert(WorkflowEvent(
                phase: .onboarding,
                title: "Codex CLI installed",
                detail: state.executablePath ?? "Codex is available on this Mac.",
                risk: .informational
            ), at: 0)
        } catch {
            aiConnectionState = .failed
            codexStatusMessage = error.localizedDescription
            events.insert(WorkflowEvent(
                phase: .onboarding,
                title: "Codex install failed",
                detail: error.localizedDescription,
                risk: .medium
            ), at: 0)
        }
        isInstallingCodex = false
    }

    func connectAI(deviceAuth: Bool = false) async {
        isLoggingIntoCodex = true
        aiConnectionState = .checking
        let currentState = await codexClient.probeAuthentication()
        applyCodexState(currentState)

        guard currentState.isInstalled else {
            isLoggingIntoCodex = false
            return
        }
        guard !currentState.isLoggedIn else {
            isLoggingIntoCodex = false
            return
        }

        do {
            let state = try await codexClient.login(deviceAuth: deviceAuth)
            applyCodexState(state)
            events.insert(WorkflowEvent(
                phase: .onboarding,
                title: "Codex authenticated",
                detail: "LaunchKit can now route AI analysis through the local ChatGPT-authenticated Codex CLI.",
                risk: .informational
            ), at: 0)
        } catch {
            aiConnectionState = .failed
            codexStatusMessage = error.localizedDescription
            events.insert(WorkflowEvent(
                phase: .onboarding,
                title: "Codex login did not complete",
                detail: error.localizedDescription,
                risk: .medium
            ), at: 0)
        }
        isLoggingIntoCodex = false
    }

    func connectApple() async {
        isConnectingApple = true
        appleConnectionState = .checking
        let environment = await appleProbe.probe()
        appleEnvironment = environment
        appleConnectionState = environment.isUsable ? (environment.diagnostics.isEmpty ? .connected : .limited) : .failed
        appleConnectionMessage = appleSummary(for: environment)
        events.insert(WorkflowEvent(
            phase: .onboarding,
            title: "Apple environment checked",
            detail: appleConnectionMessage,
            risk: environment.diagnostics.isEmpty ? .informational : .medium
        ), at: 0)
        isConnectingApple = false
    }

    func generateReleasePlan() async {
        guard await ensureCodexConnected(phase: .planning, taskName: "generate a release plan") else { return }

        isGeneratingReleasePlan = true
        do {
            let prompt = codexClient.releasePlanPrompt(scan: scanResult)
            generatedReleasePlan = try await codexClient.complete(
                prompt: prompt,
                workingDirectoryURL: scanResult?.rootURL
            )
            selectedScreen = .releasePlan
            events.insert(WorkflowEvent(
                phase: .planning,
                title: "Codex generated release plan",
                detail: "Generated a review-gated release plan from local scan evidence.",
                risk: .informational
            ), at: 0)
        } catch {
            events.insert(WorkflowEvent(
                phase: .planning,
                title: "Release plan generation failed",
                detail: error.localizedDescription,
                risk: .medium
            ), at: 0)
        }
        isGeneratingReleasePlan = false
    }

    func regenerateScreenshotDraft() async {
        guard await ensureCodexConnected(phase: .screenshots, taskName: "regenerate screenshots") else { return }

        isGeneratingScreenshotDraft = true
        do {
            let prompt = codexClient.screenshotDraftPrompt(scan: scanResult)
            let output = try await codexClient.complete(
                prompt: prompt,
                workingDirectoryURL: scanResult?.rootURL
            )
            generatedScreenshotDraft = GeneratedScreenshotDraft(output: output)
            events.insert(WorkflowEvent(
                phase: .screenshots,
                title: "Codex regenerated screenshot draft",
                detail: generatedScreenshotDraft?.caption ?? "Generated a new screenshot concept.",
                risk: .informational
            ), at: 0)
        } catch {
            events.insert(WorkflowEvent(
                phase: .screenshots,
                title: "Screenshot draft generation failed",
                detail: error.localizedDescription,
                risk: .medium
            ), at: 0)
        }
        isGeneratingScreenshotDraft = false
    }

    func generateMetadataDraft() async {
        guard await ensureCodexConnected(phase: .metadata, taskName: "draft App Store metadata") else { return }

        isGeneratingMetadataDraft = true
        do {
            let prompt = codexClient.metadataDraftPrompt(scan: scanResult, releasePlan: generatedReleasePlan)
            generatedMetadataDraft = try await codexClient.complete(
                prompt: prompt,
                workingDirectoryURL: scanResult?.rootURL
            )
            selectedScreen = .metadata
            events.insert(WorkflowEvent(
                phase: .metadata,
                title: "Codex generated metadata draft",
                detail: "Generated editable App Store copy with assumptions and approval gates.",
                risk: .informational
            ), at: 0)
        } catch {
            events.insert(WorkflowEvent(
                phase: .metadata,
                title: "Metadata generation failed",
                detail: error.localizedDescription,
                risk: .medium
            ), at: 0)
        }
        isGeneratingMetadataDraft = false
    }

    func generateIAPDraft() async {
        guard await ensureCodexConnected(phase: .payments, taskName: "prepare IAP drafts") else { return }

        isGeneratingIAPDraft = true
        do {
            let prompt = codexClient.iapDraftPrompt(scan: scanResult)
            generatedIAPDraft = try await codexClient.complete(
                prompt: prompt,
                workingDirectoryURL: scanResult?.rootURL
            )
            selectedScreen = .payments
            events.insert(WorkflowEvent(
                phase: .payments,
                title: "Codex generated IAP draft",
                detail: "Generated local StoreKit and approval-gated monetization setup notes.",
                risk: .informational
            ), at: 0)
        } catch {
            events.insert(WorkflowEvent(
                phase: .payments,
                title: "IAP draft generation failed",
                detail: error.localizedDescription,
                risk: .medium
            ), at: 0)
        }
        isGeneratingIAPDraft = false
    }

    func prepareSafeFixReview() {
        let reversibleWrites = plannedActions.filter { $0.category == .safeReversibleWrite }
        events.insert(WorkflowEvent(
            phase: .fixing,
            title: "Safe fix review prepared",
            detail: reversibleWrites.isEmpty
                ? "No reversible write fixes are available for the current scan."
                : "\(reversibleWrites.count) reversible write fix is ready for diff and rollback review.",
            risk: reversibleWrites.isEmpty ? .informational : .medium
        ), at: 0)
        selectedScreen = .releasePlan
    }

    private func ensureCodexConnected(phase: WorkflowPhase, taskName: String) async -> Bool {
        if aiConnectionState != .connected {
            await refreshCodexStatus()
        }
        guard aiConnectionState == .connected else {
            events.insert(WorkflowEvent(
                phase: phase,
                title: "Codex login required",
                detail: "Connect Codex before asking LaunchKit to \(taskName).",
                risk: .medium
            ), at: 0)
            return false
        }
        return true
    }

    private func applyCodexState(_ state: CodexAuthenticationState) {
        codexAuthenticationState = state
        codexStatusMessage = state.statusText
        if !state.isInstalled {
            aiConnectionState = .missing
        } else if state.isLoggedIn {
            aiConnectionState = .connected
        } else {
            aiConnectionState = .loginRequired
        }
    }

    private func appleSummary(for environment: AppleDeveloperEnvironment) -> String {
        var parts: [String] = []
        if let xcodeVersion = environment.xcodeVersion {
            parts.append(xcodeVersion.replacingOccurrences(of: "\n", with: " "))
        } else {
            parts.append("Xcode command line tools were not found.")
        }
        parts.append("\(environment.codeSigningIdentityCount) local signing identities")
        parts.append(environment.transporterAvailable ? "Transporter available" : "Transporter unavailable")
        if !environment.diagnostics.isEmpty {
            parts.append(environment.diagnostics.joined(separator: " "))
        }
        return parts.joined(separator: ". ")
    }

    func openCodexInstallPage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/openai/codex")!)
    }

    func openProjectFolder(_ project: DiscoveredProjectCandidate) {
        NSWorkspace.shared.activateFileViewerSelecting([project.rootURL])
    }

    func openCodexLoginHelp() {
        NSWorkspace.shared.open(URL(string: "https://developers.openai.com/codex")!)
    }

    func insertGeneratedPlanIntoTimeline() {
        guard let generatedReleasePlan else { return }
        events.insert(WorkflowEvent(
            phase: .planning,
            title: "Release plan reviewed",
            detail: String(generatedReleasePlan.prefix(220)),
            risk: .informational
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
    case missing = "Missing CLI"
    case checking = "Checking"
    case installing = "Installing"
    case loginRequired = "Login required"
    case connected = "Connected"
    case limited = "Limited"
    case failed = "Failed"
}

struct GeneratedScreenshotDraft: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var caption: String
    var visualDirection: String
    var paletteIndex: Int

    init(title: String, caption: String, visualDirection: String, paletteIndex: Int = 0) {
        self.title = title
        self.caption = caption
        self.visualDirection = visualDirection
        self.paletteIndex = paletteIndex
    }

    init(output: String) {
        let lines = output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.title = Self.value(after: "Title:", in: lines) ?? "Ship With Confidence"
        self.caption = Self.value(after: "Caption:", in: lines) ?? "Every release step reviewed before it reaches Apple."
        self.visualDirection = Self.value(after: "Visual Direction:", in: lines) ?? output
        self.paletteIndex = abs(output.hashValue % Self.palettes.count)
    }

    var palette: [Color] {
        Self.palettes[paletteIndex % Self.palettes.count]
    }

    static let defaultDraft = GeneratedScreenshotDraft(
        title: "Release Without Xcode Friction",
        caption: "Scan, fix, build, and submit with transparent approval gates.",
        visualDirection: "A calm macOS release cockpit with a concise timeline, approval states, and polished App Store screenshot framing.",
        paletteIndex: 0
    )

    private static let palettes: [[Color]] = [
        [
            Color(red: 0.05, green: 0.07, blue: 0.10),
            Color(red: 0.00, green: 0.46, blue: 0.52),
            Color(red: 0.95, green: 0.50, blue: 0.25)
        ],
        [
            Color(red: 0.08, green: 0.10, blue: 0.12),
            Color(red: 0.23, green: 0.50, blue: 0.38),
            Color(red: 0.92, green: 0.73, blue: 0.35)
        ],
        [
            Color(red: 0.07, green: 0.09, blue: 0.16),
            Color(red: 0.60, green: 0.23, blue: 0.42),
            Color(red: 0.20, green: 0.62, blue: 0.82)
        ]
    ]

    private static func value(after prefix: String, in lines: [String]) -> String? {
        lines.first { $0.localizedCaseInsensitiveContains(prefix) }?
            .replacingOccurrences(of: prefix, with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
                ReleasePlanView(model: model)
            case .buildMonitor:
                BuildMonitorView(events: model.events)
            case .screenshots:
                ScreenshotGalleryView(model: model)
            case .metadata:
                MetadataEditorView(model: model)
            case .payments:
                PaymentsManagerView(model: model)
            case .compliance:
                ComplianceView(findings: model.findings)
            case .submission:
                SubmissionReviewView(model: model)
            case .settings:
                SettingsView(model: model)
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
                        title: "Connect Codex",
                        status: model.isCheckingCodex ? "Checking" : model.aiConnectionState.rawValue,
                        bodyText: "LaunchKit uses ChatGPT-authenticated Codex through the local Codex CLI. It does not ask for provider API keys.",
                        buttonTitle: codexButtonTitle,
                        systemImage: "sparkles"
                    ) {
                        Task {
                            switch model.aiConnectionState {
                            case .missing:
                                await model.installCodex()
                            case .connected:
                                await model.refreshCodexStatus()
                            default:
                                await model.connectAI()
                            }
                        }
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
                        status: model.isConnectingApple ? "Checking" : model.appleConnectionState.rawValue,
                        bodyText: "LaunchKit checks local Xcode, signing identities, and Transporter first so API-key setup is an advanced fallback, not the first step.",
                        buttonTitle: model.isConnectingApple ? "Checking..." : "Check Apple",
                        systemImage: "apple.logo"
                    ) {
                        Task { await model.connectApple() }
                    }
                }

                ConnectionSummary(model: model)

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

                AutomationPreview(model: model)

                WorkflowTimeline(events: model.events)
            }
            .padding(32)
        }
        .task {
            if model.codexAuthenticationState == nil {
                await model.refreshCodexStatus()
            }
        }
    }

    private var codexButtonTitle: String {
        if model.isInstallingCodex { return "Installing..." }
        if model.isLoggingIntoCodex { return "Opening Login..." }
        switch model.aiConnectionState {
        case .missing: return "Install Codex"
        case .connected: return "Recheck"
        case .loginRequired, .failed, .notConnected: return "Open Login"
        case .checking: return "Checking..."
        case .installing: return "Installing..."
        case .limited: return "Open Login"
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

struct ConnectionSummary: View {
    @Bindable var model: LaunchKitAppModel

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], spacing: 16) {
            StatusPanel(
                title: "Codex Account",
                status: model.aiConnectionState.rawValue,
                detail: model.codexStatusMessage,
                footnote: model.codexAuthenticationState?.executablePath ?? "Install path will appear after detection.",
                actionTitle: "Device Login",
                systemImage: "person.crop.circle.badge.checkmark"
            ) {
                Task { await model.connectAI(deviceAuth: true) }
            }

            StatusPanel(
                title: "Apple Developer Environment",
                status: model.appleConnectionState.rawValue,
                detail: model.appleConnectionMessage,
                footnote: "Xcode automatic signing is preferred before API-key fallback.",
                actionTitle: "Recheck",
                systemImage: "hammer"
            ) {
                Task { await model.connectApple() }
            }
        }
    }
}

struct StatusPanel: View {
    let title: String
    let status: String
    let detail: String
    let footnote: String
    let actionTitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer()
                Text(status)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.tertiary, in: Capsule())
            }
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct AutomationPreview: View {
    @Bindable var model: LaunchKitAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI-Generated Release Flow")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                FlowChip(title: "Scan and explain", icon: "text.magnifyingglass") {
                    Task { await model.discoverProjects() }
                }
                FlowChip(title: "Auto-fix safe issues", icon: "wand.and.sparkles") {
                    model.prepareSafeFixReview()
                }
                FlowChip(title: model.isGeneratingScreenshotDraft ? "Regenerating..." : "Regenerate screenshots", icon: "photo.stack") {
                    Task { await model.regenerateScreenshotDraft() }
                }
                FlowChip(title: model.isGeneratingMetadataDraft ? "Drafting..." : "Draft metadata", icon: "doc.text") {
                    Task { await model.generateMetadataDraft() }
                }
                FlowChip(title: model.isGeneratingIAPDraft ? "Preparing..." : "Prepare IAPs", icon: "creditcard") {
                    Task { await model.generateIAPDraft() }
                }
                FlowChip(title: "Generate release plan", icon: "checklist.checked") {
                    Task { await model.generateReleasePlan() }
                }
            }
        }
    }
}

struct FlowChip: View {
    let title: String
    let icon: String
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
                    .font(.callout.weight(.medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
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
    @Bindable var model: LaunchKitAppModel
    private let policyEngine = PolicyEngine()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderBlock(
                    eyebrow: "Policy-controlled execution",
                    title: "Release Plan",
                    subtitle: "Each proposed action declares its risk, approval requirement, affected files, and rollback behavior before execution."
                )

                HStack(spacing: 12) {
                    Button {
                        Task { await model.generateReleasePlan() }
                    } label: {
                        Label(model.isGeneratingReleasePlan ? "Generating..." : "Generate With Codex", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isGeneratingReleasePlan)

                    Button("Mark Draft Reviewed") {
                        model.insertGeneratedPlanIntoTimeline()
                    }
                    .disabled(model.generatedReleasePlan == nil)
                }

                if let generatedReleasePlan = model.generatedReleasePlan {
                    Text(generatedReleasePlan)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                ForEach(model.plannedActions) { action in
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

struct ScreenshotGalleryView: View {
    @Bindable var model: LaunchKitAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderBlock(
                    eyebrow: "Public asset review",
                    title: "Screenshot Gallery",
                    subtitle: "Codex generates screenshot concepts through the local CLI. LaunchKit renders reviewable drafts locally and keeps upload as an approval-gated public-facing action."
                )

                HStack(spacing: 12) {
                    Button {
                        Task { await model.regenerateScreenshotDraft() }
                    } label: {
                        Label(model.isGeneratingScreenshotDraft ? "Regenerating..." : "Regenerate Draft", systemImage: "photo.stack")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isGeneratingScreenshotDraft)

                    Text("Generated assets stay local until explicitly approved.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                GeneratedScreenshotPreview(draft: model.generatedScreenshotDraft ?? .defaultDraft)
            }
            .padding(32)
        }
    }
}

struct GeneratedScreenshotPreview: View {
    let draft: GeneratedScreenshotDraft

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: draft.palette, startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Image(systemName: "app.badge.checkmark")
                            .font(.system(size: 30, weight: .semibold))
                        Spacer()
                        Text("DRAFT")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.22), in: Capsule())
                    }
                    Spacer()
                    Text(draft.title)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(draft.caption)
                        .font(.title3.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.white)
                .padding(28)
            }
            .frame(width: 360, height: 640)
            .shadow(color: .black.opacity(0.18), radius: 24, y: 12)

            VStack(alignment: .leading, spacing: 12) {
                Text("Visual Direction")
                    .font(.headline)
                Text(draft.visualDirection)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Text("Approval Gate")
                    .font(.headline)
                Text("Screenshots are public-facing assets. LaunchKit can generate and render drafts locally, but upload remains blocked until a human approves the final gallery.")
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: 420, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

struct MetadataEditorView: View {
    @Bindable var model: LaunchKitAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderBlock(
                    eyebrow: "Editable public copy",
                    title: "Metadata Editor",
                    subtitle: "Descriptions, release notes, keywords, review notes, privacy drafts, and demo credentials are editable and diffable before any App Store Connect write."
                )
                Button {
                    Task { await model.generateMetadataDraft() }
                } label: {
                    Label(model.isGeneratingMetadataDraft ? "Drafting..." : "Generate With Codex", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isGeneratingMetadataDraft)

                if let generatedMetadataDraft = model.generatedMetadataDraft {
                    Text(generatedMetadataDraft)
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    MetadataDraftPanel(
                        title: "Local Draft Fields",
                        rows: [
                            ("Subtitle", "AI-powered release agent for Apple developers"),
                            ("Keywords", "release, testflight, xcode, signing, screenshots"),
                            ("Release Notes", model.generatedReleasePlan ?? "Generate a Codex release plan to seed release notes from scan evidence."),
                            ("Review Notes", "Provide reviewer credentials and explain gated functionality before submission.")
                        ]
                    )
                }
            }
            .padding(32)
        }
    }
}

struct MetadataDraftPanel: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.0)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(row.1)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct PaymentsManagerView: View {
    @Bindable var model: LaunchKitAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderBlock(
                    eyebrow: "Revenue approval gate",
                    title: "IAP Manager",
                    subtitle: "LaunchKit can draft StoreKit products and subscription groups locally. Names, pricing, and live monetization changes always require explicit approval."
                )
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                    PaymentDraftCard(title: "LaunchKit Pro Monthly", type: "Subscription", status: "Draft")
                    PaymentDraftCard(title: "Lifetime Unlock", type: "Non-consumable", status: "Draft")
                    PaymentDraftCard(title: "Sandbox Purchases", type: "Test Setup", status: model.scanResult == nil ? "Waiting for scan" : "Ready")
                }
                Button {
                    Task { await model.generateIAPDraft() }
                } label: {
                    Label(model.isGeneratingIAPDraft ? "Preparing..." : "Generate IAP Plan With Codex", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isGeneratingIAPDraft)

                if let generatedIAPDraft = model.generatedIAPDraft {
                    Text(generatedIAPDraft)
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(32)
        }
    }
}

struct PaymentDraftCard: View {
    let title: String
    let type: String
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "creditcard")
                Spacer()
                Text(status)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.tertiary, in: Capsule())
            }
            Text(title)
                .font(.headline)
            Text(type)
                .foregroundStyle(.secondary)
            Text("Requires explicit approval before App Store Connect mutation.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SubmissionReviewView: View {
    @Bindable var model: LaunchKitAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderBlock(
                    eyebrow: "Final human approval",
                    title: "Final Submission Review",
                    subtitle: "Submission is intentionally separated from upload. LaunchKit summarizes build, metadata, screenshots, privacy, IAP, and compliance evidence before the final handoff."
                )
                ForEach(Array(submissionItems.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Image(systemName: item.1)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.0)
                                .font(.headline)
                            Text(item.2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(item.3)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.tertiary, in: Capsule())
                    }
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(32)
        }
    }

    private var submissionItems: [(String, String, String, String)] {
        [
            ("Project Scan", "waveform.path.ecg.rectangle", model.scanResult == nil ? "No selected project has been scanned." : "Scan evidence is attached.", model.scanResult == nil ? "Required" : "Ready"),
            ("Codex Plan", "sparkles", model.generatedReleasePlan == nil ? "Generate or review the release plan." : "AI draft is available.", model.generatedReleasePlan == nil ? "Required" : "Ready"),
            ("Screenshots", "photo.on.rectangle", model.generatedScreenshotDraft == nil ? "Generate and approve screenshot drafts." : "Screenshot draft is available for review.", model.generatedScreenshotDraft == nil ? "Review" : "Draft"),
            ("Apple Environment", "apple.logo", model.appleConnectionMessage, model.appleConnectionState.rawValue)
        ]
    }
}

struct SettingsView: View {
    @Bindable var model: LaunchKitAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderBlock(
                eyebrow: "Local-first secrets",
                title: "Settings & Secrets",
                subtitle: "Codex authentication is owned by the local Codex CLI. Apple signing material, repository access, and advanced App Store Connect keys stay local by default."
            )
            StatusPanel(
                title: "Codex CLI",
                status: model.aiConnectionState.rawValue,
                detail: model.codexStatusMessage,
                footnote: model.codexAuthenticationState?.version ?? "Version unavailable",
                actionTitle: "Check Status",
                systemImage: "terminal"
            ) {
                Task { await model.refreshCodexStatus() }
            }
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
