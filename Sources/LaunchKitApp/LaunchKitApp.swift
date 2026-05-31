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
            LaunchKitMainView(model: model)
                .frame(minWidth: 1120, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

@Observable
@MainActor
final class LaunchKitAppModel {
    var selectedScreen: LaunchKitScreen = .home
    var selectedProject: DiscoveredProjectCandidate?
    var scanResult: ProjectScanResult?
    var findings: [DiagnosticFinding] = LaunchKitSampleData.findings
    var plannedActions: [LaunchKitAction] = LaunchKitSampleData.actions
    var events: [WorkflowEvent] = LaunchKitSampleData.events
    var discoveredProjects: [DiscoveredProjectCandidate] = []
    var releaseKits: [String: ReleaseKitState] = [:]
    var isDiscoveringProjects = false
    var selectedAIProvider: LocalAgentProvider = .codex {
        didSet { aiConnectionState = connectionState(for: selectedAIProvider) }
    }
    var isCheckingAgent = false
    var isInstallingAgent = false
    var isLoggingIntoAgent = false
    var isGeneratingReleasePlan = false
    var isGeneratingScreenshotDraft = false
    var isGeneratingMetadataDraft = false
    var isGeneratingIAPDraft = false
    var isGeneratingReleaseKit = false
    var hasStartedReleaseKit = false
    var didBootstrap = false
    var releaseKitStatus = "Ready"
    var releasePlanStatus: ReleaseKitSectionStatus = .pending
    var metadataStatus: ReleaseKitSectionStatus = .pending
    var screenshotStatus: ReleaseKitSectionStatus = .pending
    var iapStatus: ReleaseKitSectionStatus = .pending
    var riskStatus: ReleaseKitSectionStatus = .pending
    var appleToolsStatus: ReleaseKitSectionStatus = .pending
    var isConnectingApple = false
    var aiConnectionState: ConnectionState = .notConnected
    var appleConnectionState: ConnectionState = .notConnected
    var agentAuthenticationStates: [LocalAgentProvider: LocalAgentAuthenticationState] = [:]
    var agentConnectionStates: [LocalAgentProvider: ConnectionState] = [
        .codex: .notConnected,
        .claude: .notConnected
    ]
    var agentStatusMessages: [LocalAgentProvider: String] = [
        .codex: "Codex status has not been checked yet.",
        .claude: "Claude Code status has not been checked yet."
    ]
    var appleEnvironment: AppleDeveloperEnvironment?
    var appleConnectionMessage = "Apple developer environment has not been checked yet."
    var generatedReleasePlan: String?
    var generatedScreenshotDraft: GeneratedScreenshotDraft?
    var generatedMetadataDraft: String?
    var generatedIAPDraft: String?

    private let scanner = FileSystemProjectScanner()
    private let discoveryService = ProjectDiscoveryService()
    private let localAgentBridge = LocalAgentBridge()
    private let appleProbe = AppleDeveloperEnvironmentProbe()

    var isAIReady: Bool {
        connectionState(for: selectedAIProvider) == .connected
    }

    var selectedProjectName: String {
        selectedProject?.name ?? "No app selected"
    }

    func releaseKit(for project: DiscoveredProjectCandidate) -> ReleaseKitState {
        releaseKits[project.id] ?? ReleaseKitState()
    }

    var riskDisplayStatus: String {
        switch riskStatus {
        case .ready:
            findings.isEmpty ? "Clear" : "\(findings.count)"
        default:
            riskStatus.rawValue
        }
    }

    var appleToolsDisplayStatus: String {
        switch appleToolsStatus {
        case .ready:
            appleConnectionState.rawValue
        default:
            appleToolsStatus.rawValue
        }
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await refreshAllAgentStatuses()
        if !isAIReady,
           let connectedProvider = LocalAgentProvider.allCases.first(where: { connectionState(for: $0) == .connected }) {
            selectedAIProvider = connectedProvider
        }
        await discoverProjects()
        if selectedProject == nil {
            selectedProject = discoveredProjects.first
        }
    }

    func refreshAgentStatus(provider: LocalAgentProvider) async {
        isCheckingAgent = true
        let state = await localAgentBridge.probeAuthentication(provider: provider)
        applyAgentState(state)
        isCheckingAgent = false
    }

    func refreshAllAgentStatuses() async {
        isCheckingAgent = true
        async let codex = localAgentBridge.probeAuthentication(provider: .codex)
        async let claude = localAgentBridge.probeAuthentication(provider: .claude)
        await [codex, claude].forEach(applyAgentState)
        isCheckingAgent = false
    }

    func installAgent(provider: LocalAgentProvider) async {
        selectedAIProvider = provider
        isInstallingAgent = true
        setConnectionState(.installing, for: provider)
        do {
            let state = try await localAgentBridge.installWithNPM(provider: provider)
            applyAgentState(state)
            events.insert(WorkflowEvent(
                phase: .onboarding,
                title: "\(provider.displayName) installed",
                detail: state.executablePath ?? "\(provider.displayName) is available on this Mac.",
                risk: .informational
            ), at: 0)
        } catch {
            setConnectionState(.failed, for: provider)
            agentStatusMessages[provider] = error.localizedDescription
            events.insert(WorkflowEvent(
                phase: .onboarding,
                title: "\(provider.displayName) install failed",
                detail: error.localizedDescription,
                risk: .medium
            ), at: 0)
        }
        isInstallingAgent = false
    }

    func connectAI(provider: LocalAgentProvider, mode: LocalAgentLoginMode = .browser) async {
        selectedAIProvider = provider
        isLoggingIntoAgent = true
        setConnectionState(.checking, for: provider)
        let currentState = await localAgentBridge.probeAuthentication(provider: provider)
        applyAgentState(currentState)

        guard currentState.isInstalled else {
            isLoggingIntoAgent = false
            return
        }
        guard !currentState.isLoggedIn else {
            isLoggingIntoAgent = false
            return
        }

        do {
            let state = try await localAgentBridge.login(provider: provider, mode: mode)
            applyAgentState(state)
            events.insert(WorkflowEvent(
                phase: .onboarding,
                title: "\(provider.displayName) authenticated",
                detail: "LaunchKit can now route AI analysis through local \(provider.subscriptionLabel).",
                risk: .informational
            ), at: 0)
        } catch {
            setConnectionState(.failed, for: provider)
            agentStatusMessages[provider] = error.localizedDescription
            events.insert(WorkflowEvent(
                phase: .onboarding,
                title: "\(provider.displayName) login did not complete",
                detail: error.localizedDescription,
                risk: .medium
            ), at: 0)
        }
        isLoggingIntoAgent = false
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
        guard await ensureSelectedAgentConnected(phase: .planning, taskName: "generate a release plan") else { return }

        isGeneratingReleasePlan = true
        do {
            let prompt = localAgentBridge.releasePlanPrompt(provider: selectedAIProvider, scan: scanResult)
            generatedReleasePlan = try await localAgentBridge.complete(
                provider: selectedAIProvider,
                prompt: prompt,
                workingDirectoryURL: scanResult?.rootURL
            )
            selectedScreen = .releasePlan
            events.insert(WorkflowEvent(
                phase: .planning,
                title: "\(selectedAIProvider.displayName) generated release plan",
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
        guard await ensureSelectedAgentConnected(phase: .screenshots, taskName: "regenerate screenshots") else { return }

        isGeneratingScreenshotDraft = true
        do {
            let prompt = localAgentBridge.screenshotDraftPrompt(provider: selectedAIProvider, scan: scanResult)
            let output = try await localAgentBridge.complete(
                provider: selectedAIProvider,
                prompt: prompt,
                workingDirectoryURL: scanResult?.rootURL
            )
            generatedScreenshotDraft = GeneratedScreenshotDraft(output: output)
            events.insert(WorkflowEvent(
                phase: .screenshots,
                title: "\(selectedAIProvider.displayName) regenerated screenshot draft",
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
        guard await ensureSelectedAgentConnected(phase: .metadata, taskName: "draft App Store metadata") else { return }

        isGeneratingMetadataDraft = true
        do {
            let prompt = localAgentBridge.metadataDraftPrompt(
                provider: selectedAIProvider,
                scan: scanResult,
                releasePlan: generatedReleasePlan
            )
            generatedMetadataDraft = try await localAgentBridge.complete(
                provider: selectedAIProvider,
                prompt: prompt,
                workingDirectoryURL: scanResult?.rootURL
            )
            selectedScreen = .metadata
            events.insert(WorkflowEvent(
                phase: .metadata,
                title: "\(selectedAIProvider.displayName) generated metadata draft",
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
        guard await ensureSelectedAgentConnected(phase: .payments, taskName: "prepare IAP drafts") else { return }

        isGeneratingIAPDraft = true
        do {
            let prompt = localAgentBridge.iapDraftPrompt(provider: selectedAIProvider, scan: scanResult)
            generatedIAPDraft = try await localAgentBridge.complete(
                provider: selectedAIProvider,
                prompt: prompt,
                workingDirectoryURL: scanResult?.rootURL
            )
            selectedScreen = .payments
            events.insert(WorkflowEvent(
                phase: .payments,
                title: "\(selectedAIProvider.displayName) generated IAP draft",
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

    func selectProject(_ project: DiscoveredProjectCandidate) {
        selectedProject = project
    }

    func generateReleaseKit() async {
        guard let project = selectedProject else { return }
        await generateReleaseKit(for: project)
    }

    func generateReleaseKit(for project: DiscoveredProjectCandidate) async {
        guard await ensureSelectedAgentConnected(phase: .planning, taskName: "generate the release kit") else { return }

        let projectID = project.id
        let provider = selectedAIProvider
        resetReleaseKit(for: projectID)
        updateReleaseKit(for: projectID) { kit in
            kit.hasStartedReleaseKit = true
            kit.isGeneratingReleaseKit = true
            kit.releaseKitStatus = "Starting"
        }
        defer {
            updateReleaseKit(for: projectID) { kit in
                kit.isGeneratingReleaseKit = false
                kit.isGeneratingReleasePlan = false
                kit.isGeneratingMetadataDraft = false
                kit.isGeneratingScreenshotDraft = false
                kit.isGeneratingIAPDraft = false
            }
        }

        do {
            updateReleaseKit(for: projectID) { kit in
                kit.releaseKitStatus = "Reading \(project.name)"
                kit.riskStatus = .generating
            }
            let result = try await scanner.scan(rootURL: project.rootURL)
            updateReleaseKit(for: projectID) { kit in
                let displayName = result.appContext.preferredDisplayName ?? project.name
                kit.scanResult = result
                kit.findings = result.findings
                kit.metadataForm = AppStoreMetadataForm.fallback(projectName: project.name, scan: result)
                kit.screenshotAssets = ScreenshotReviewAsset.defaults(projectName: displayName)
                kit.iapForm = IAPReviewForm.fallback(scan: result)
                kit.riskStatus = .ready
                kit.releaseKitStatus = "Writing release plan"
                kit.releasePlanStatus = .generating
                kit.isGeneratingReleasePlan = true
            }

            let releasePlan = fallbackReleasePlan(project: project, scan: result)
            updateReleaseKit(for: projectID) { kit in
                kit.generatedReleasePlan = releasePlan
                kit.releasePlanStatus = .generating
                kit.metadataStatus = .generating
                kit.screenshotStatus = .generating
                kit.iapStatus = .generating
                kit.appleToolsStatus = .generating
                kit.isGeneratingMetadataDraft = true
                kit.isGeneratingScreenshotDraft = true
                kit.isGeneratingIAPDraft = true
                kit.releaseKitStatus = "Generating review sections"
            }

            await generateRemainingReleaseKitSections(
                scan: result,
                projectID: projectID,
                provider: provider,
                releasePlan: releasePlan
            )

            updateReleaseKit(for: projectID) { kit in
                kit.releaseKitStatus = "Ready for review"
            }
            events.insert(WorkflowEvent(
                phase: .planning,
                title: "Release kit generated",
                detail: "\(project.name) is ready for review.",
                risk: .informational
            ), at: 0)
        } catch {
            updateReleaseKit(for: projectID) { kit in
                kit.releaseKitStatus = "Stopped"
                if kit.riskStatus == .generating { kit.riskStatus = .failed }
                if kit.releasePlanStatus == .generating { kit.releasePlanStatus = .failed }
            }
            events.insert(WorkflowEvent(
                phase: .planning,
                title: "Release kit generation failed",
                detail: error.localizedDescription,
                risk: .medium
            ), at: 0)
        }
    }

    private func updateReleaseKit(for projectID: String, _ update: (inout ReleaseKitState) -> Void) {
        var kit = releaseKits[projectID] ?? ReleaseKitState()
        update(&kit)
        releaseKits[projectID] = kit
    }

    private func resetReleaseKit(for projectID: String) {
        releaseKits[projectID] = ReleaseKitState()
    }

    private func fallbackReleasePlan(
        project: DiscoveredProjectCandidate,
        scan: ProjectScanResult
    ) -> String {
        let blockers = scan.findings.filter { $0.severity == .blocker }.count
        return """
        Review \(project.name), fix \(blockers) blocker\(blockers == 1 ? "" : "s"), confirm metadata, confirm screenshots, then build and upload only after approval.
        """
    }

    func updateMetadataField(projectID: String, field: AppStoreMetadataField, value: String) {
        updateReleaseKit(for: projectID) { kit in
            kit.metadataForm.update(field, value: value)
        }
    }

    func addScreenshotAsset(projectID: String) {
        updateReleaseKit(for: projectID) { kit in
            let nextIndex = kit.screenshotAssets.count
            kit.screenshotAssets.append(ScreenshotReviewAsset(
                title: "Screenshot \(nextIndex + 1)",
                caption: "Add the caption users should see on this App Store image.",
                device: "iPhone 6.7\"",
                visualDirection: "Generated screenshot slot ready for review.",
                paletteIndex: nextIndex
            ))
            kit.screenshotStatus = .review
        }
    }

    func deleteScreenshotAsset(projectID: String, assetID: UUID) {
        updateReleaseKit(for: projectID) { kit in
            kit.screenshotAssets.removeAll { $0.id == assetID }
        }
    }

    func updateScreenshotAsset(
        projectID: String,
        assetID: UUID,
        field: ScreenshotAssetField,
        value: String
    ) {
        updateReleaseKit(for: projectID) { kit in
            guard let index = kit.screenshotAssets.firstIndex(where: { $0.id == assetID }) else { return }
            kit.screenshotAssets[index].update(field, value: value)
        }
    }

    func setIAPEnabled(projectID: String, isEnabled: Bool) {
        updateReleaseKit(for: projectID) { kit in
            kit.iapForm.isEnabled = isEnabled
            if isEnabled, kit.iapForm.products.isEmpty {
                kit.iapForm.products = [
                    IAPProductDraft(
                        productID: "premium_monthly",
                        displayName: "Premium Monthly",
                        kind: .autoRenewable,
                        reviewNote: "Confirm benefits, price, and subscription terms before creating this in App Store Connect."
                    )
                ]
            }
            kit.iapStatus = .review
        }
    }

    func updateIAPSetupNote(projectID: String, value: String) {
        updateReleaseKit(for: projectID) { kit in
            kit.iapForm.setupNote = value
        }
    }

    func addIAPProduct(projectID: String) {
        updateReleaseKit(for: projectID) { kit in
            kit.iapForm.isEnabled = true
            kit.iapForm.products.append(IAPProductDraft(
                productID: "product_\(kit.iapForm.products.count + 1)",
                displayName: "New Product",
                kind: .nonConsumable,
                reviewNote: "Review product details before any live App Store Connect change."
            ))
            kit.iapStatus = .review
        }
    }

    func deleteIAPProduct(projectID: String, productID: UUID) {
        updateReleaseKit(for: projectID) { kit in
            kit.iapForm.products.removeAll { $0.id == productID }
            if kit.iapForm.products.isEmpty {
                kit.iapForm.isEnabled = false
            }
        }
    }

    func updateIAPProduct(
        projectID: String,
        productID: UUID,
        field: IAPProductField,
        value: String
    ) {
        updateReleaseKit(for: projectID) { kit in
            guard let index = kit.iapForm.products.firstIndex(where: { $0.id == productID }) else { return }
            kit.iapForm.products[index].update(field, value: value)
        }
    }

    func updateIAPProductKind(projectID: String, productID: UUID, kind: IAPProductKind) {
        updateReleaseKit(for: projectID) { kit in
            guard let index = kit.iapForm.products.firstIndex(where: { $0.id == productID }) else { return }
            kit.iapForm.products[index].kind = kind
        }
    }

    private func generateRemainingReleaseKitSections(
        scan: ProjectScanResult,
        projectID: String,
        provider: LocalAgentProvider,
        releasePlan: String
    ) async {
        await withTaskGroup(of: ReleaseKitGeneratedSection.self) { group in
            group.addTask { [localAgentBridge] in
                do {
                    let output = try await localAgentBridge.complete(
                        provider: provider,
                        prompt: localAgentBridge.releasePlanPrompt(provider: provider, scan: scan),
                        workingDirectoryURL: scan.rootURL
                    )
                    return .releasePlan(output)
                } catch {
                    return .failed(.releasePlan, error.localizedDescription)
                }
            }

            group.addTask { [localAgentBridge] in
                do {
                    let output = try await localAgentBridge.complete(
                        provider: provider,
                        prompt: localAgentBridge.metadataDraftPrompt(
                            provider: provider,
                            scan: scan,
                            releasePlan: releasePlan
                        ),
                        workingDirectoryURL: scan.rootURL
                    )
                    return .metadata(output)
                } catch {
                    return .failed(.metadata, error.localizedDescription)
                }
            }

            group.addTask { [localAgentBridge] in
                do {
                    let output = try await localAgentBridge.complete(
                        provider: provider,
                        prompt: localAgentBridge.screenshotDraftPrompt(provider: provider, scan: scan),
                        workingDirectoryURL: scan.rootURL
                    )
                    return .screenshots(output)
                } catch {
                    return .failed(.screenshots, error.localizedDescription)
                }
            }

            group.addTask { [localAgentBridge] in
                do {
                    let output = try await localAgentBridge.complete(
                        provider: provider,
                        prompt: localAgentBridge.iapDraftPrompt(provider: provider, scan: scan),
                        workingDirectoryURL: scan.rootURL
                    )
                    return .iap(output)
                } catch {
                    return .failed(.iap, error.localizedDescription)
                }
            }

            group.addTask { [appleProbe] in
                let environment = await appleProbe.probe()
                return .appleTools(environment)
            }

            for await section in group {
                applyGeneratedSection(section, projectID: projectID)
            }
        }
    }

    private func applyGeneratedSection(_ section: ReleaseKitGeneratedSection, projectID: String) {
        switch section {
        case let .releasePlan(output):
            updateReleaseKit(for: projectID) { kit in
                kit.generatedReleasePlan = output
                kit.releasePlanStatus = .ready
                kit.isGeneratingReleasePlan = false
                kit.releaseKitStatus = "Release plan ready"
            }
        case let .metadata(output):
            updateReleaseKit(for: projectID) { kit in
                kit.generatedMetadataDraft = output
                kit.metadataForm = kit.metadataForm.applying(agentOutput: output)
                kit.metadataStatus = .ready
                kit.isGeneratingMetadataDraft = false
                kit.releaseKitStatus = "Metadata ready"
            }
        case let .screenshots(output):
            updateReleaseKit(for: projectID) { kit in
                let draft = GeneratedScreenshotDraft(output: output)
                kit.generatedScreenshotDraft = draft
                if kit.screenshotAssets.isEmpty {
                    kit.screenshotAssets = [
                        ScreenshotReviewAsset(
                            title: draft.title,
                            caption: draft.caption,
                            device: "iPhone 6.7\"",
                            visualDirection: draft.visualDirection,
                            paletteIndex: draft.paletteIndex
                        )
                    ]
                } else {
                    kit.screenshotAssets[0].title = draft.title
                    kit.screenshotAssets[0].caption = draft.caption
                    kit.screenshotAssets[0].visualDirection = draft.visualDirection
                    kit.screenshotAssets[0].paletteIndex = draft.paletteIndex
                }
                kit.screenshotStatus = .review
                kit.isGeneratingScreenshotDraft = false
                kit.releaseKitStatus = "Screenshot draft ready"
            }
        case let .iap(output):
            updateReleaseKit(for: projectID) { kit in
                kit.generatedIAPDraft = output
                kit.iapForm = kit.iapForm.applying(agentOutput: output)
                kit.iapStatus = .review
                kit.isGeneratingIAPDraft = false
                kit.releaseKitStatus = "Purchases ready"
            }
        case let .appleTools(environment):
            updateReleaseKit(for: projectID) { kit in
                kit.appleEnvironment = environment
                kit.appleConnectionState = environment.isUsable ? (environment.diagnostics.isEmpty ? .connected : .limited) : .failed
                kit.appleConnectionMessage = appleSummary(for: environment)
                kit.appleToolsStatus = .ready
                kit.releaseKitStatus = "Apple tools checked"
            }
        case let .failed(section, message):
            updateReleaseKit(for: projectID) { kit in
                switch section {
                case .releasePlan:
                    kit.releasePlanStatus = .review
                    kit.isGeneratingReleasePlan = false
                case .metadata:
                    kit.metadataStatus = .review
                    kit.isGeneratingMetadataDraft = false
                case .screenshots:
                    kit.screenshotStatus = .review
                    kit.isGeneratingScreenshotDraft = false
                case .iap:
                    kit.iapStatus = .review
                    kit.isGeneratingIAPDraft = false
                case .appleTools:
                    kit.appleToolsStatus = .failed
                }
                kit.releaseKitStatus = "\(section.title) needs review"
            }
            events.insert(WorkflowEvent(
                phase: section.phase,
                title: "\(section.title) failed",
                detail: message,
                risk: .medium
            ), at: 0)
        }
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

    private func ensureSelectedAgentConnected(phase: WorkflowPhase, taskName: String) async -> Bool {
        if connectionState(for: selectedAIProvider) != .connected {
            await refreshAgentStatus(provider: selectedAIProvider)
        }
        guard connectionState(for: selectedAIProvider) == .connected else {
            events.insert(WorkflowEvent(
                phase: phase,
                title: "\(selectedAIProvider.displayName) login required",
                detail: "Connect \(selectedAIProvider.displayName) before asking LaunchKit to \(taskName).",
                risk: .medium
            ), at: 0)
            return false
        }
        return true
    }

    func connectionState(for provider: LocalAgentProvider) -> ConnectionState {
        agentConnectionStates[provider] ?? .notConnected
    }

    func statusMessage(for provider: LocalAgentProvider) -> String {
        agentStatusMessages[provider] ?? "\(provider.displayName) status has not been checked yet."
    }

    func authenticationState(for provider: LocalAgentProvider) -> LocalAgentAuthenticationState? {
        agentAuthenticationStates[provider]
    }

    private func applyAgentState(_ state: LocalAgentAuthenticationState) {
        agentAuthenticationStates[state.provider] = state
        agentStatusMessages[state.provider] = state.statusText
        if !state.isInstalled {
            setConnectionState(.missing, for: state.provider)
        } else if state.isLoggedIn {
            setConnectionState(.connected, for: state.provider)
        } else {
            setConnectionState(.loginRequired, for: state.provider)
        }
    }

    private func setConnectionState(_ state: ConnectionState, for provider: LocalAgentProvider) {
        agentConnectionStates[provider] = state
        if provider == selectedAIProvider {
            aiConnectionState = state
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

    func openAgentInstallPage(provider: LocalAgentProvider) {
        switch provider {
        case .codex:
            NSWorkspace.shared.open(URL(string: "https://github.com/openai/codex")!)
        case .claude:
            NSWorkspace.shared.open(URL(string: "https://www.anthropic.com/claude-code")!)
        }
    }

    func openProjectFolder(_ project: DiscoveredProjectCandidate) {
        NSWorkspace.shared.activateFileViewerSelecting([project.rootURL])
    }

    func openAgentLoginHelp(provider: LocalAgentProvider) {
        switch provider {
        case .codex:
            NSWorkspace.shared.open(URL(string: "https://developers.openai.com/codex")!)
        case .claude:
            NSWorkspace.shared.open(URL(string: "https://docs.anthropic.com/en/docs/claude-code")!)
        }
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
        defer { isDiscoveringProjects = false }
        let projects = await discoveryService.discover()
        discoveredProjects = projects
        if selectedProject == nil {
            selectedProject = projects.first
        } else if let selectedProject,
                  !projects.contains(where: { $0.id == selectedProject.id }) {
            self.selectedProject = projects.first
        }
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

enum ReleaseKitSectionStatus: String {
    case pending = "Pending"
    case generating = "Generating"
    case ready = "Ready"
    case review = "Review"
    case failed = "Failed"
}

enum AppStoreMetadataField {
    case name
    case subtitle
    case promotionalText
    case description
    case keywords
    case releaseNotes
    case privacyNotes
    case reviewNotes
}

struct AppStoreMetadataForm: Hashable {
    var name = ""
    var subtitle = ""
    var promotionalText = ""
    var description = ""
    var keywords = ""
    var releaseNotes = ""
    var privacyNotes = ""
    var reviewNotes = ""

    static func fallback(projectName: String, scan: ProjectScanResult?) -> AppStoreMetadataForm {
        let inferredName = scan?.appContext.preferredDisplayName ?? projectName
        let inferredDescription = scan?.appContext.preferredDescription
        let projectType = scan?.projectType.rawValue ?? "Apple"
        let capabilities = scan?.capabilities.map(\.rawValue).joined(separator: ", ")
        return AppStoreMetadataForm(
            name: inferredName,
            subtitle: subtitleFallback(projectType: projectType, contextDescription: inferredDescription),
            promotionalText: "Review this short launch message before it appears in App Store Connect.",
            description: descriptionFallback(projectName: inferredName, contextDescription: inferredDescription),
            keywords: keywordFallback(projectName: inferredName, scan: scan),
            releaseNotes: "Initial App Store release candidate prepared with LaunchKit.",
            privacyNotes: capabilities?.isEmpty == false
                ? "Review detected capabilities before answering App Store privacy questions: \(capabilities!)."
                : "Review app data collection, tracking, account deletion, and third-party SDK behavior before submission.",
            reviewNotes: "Add demo credentials, reviewer instructions, or hardware/account requirements here before submission."
        )
    }

    private static func subtitleFallback(projectType: String, contextDescription: String?) -> String {
        guard let contextDescription, !contextDescription.isEmpty else {
            return "\(projectType) app ready for review"
        }
        let firstSentence = contextDescription
            .split(separator: ".")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstSentence, !firstSentence.isEmpty else {
            return "\(projectType) app ready for review"
        }
        return String(firstSentence.prefix(70))
    }

    private static func descriptionFallback(projectName: String, contextDescription: String?) -> String {
        if let contextDescription, !contextDescription.isEmpty {
            return """
            \(contextDescription)

            Review this draft against the actual product experience before submitting to App Store Connect.
            """
        }
        return """
        \(projectName) is ready for App Store review.

        Replace this draft with a clear customer-facing description of what the app does, who it helps, and the main benefit users should expect.
        """
    }

    func applying(agentOutput: String) -> AppStoreMetadataForm {
        var form = self
        form.subtitle = Self.section("Subtitle", in: agentOutput) ?? subtitle
        form.promotionalText = Self.section("Promotional Text", in: agentOutput)
            ?? Self.section("Promotional", in: agentOutput)
            ?? promotionalText
        form.description = Self.section("Description", in: agentOutput) ?? description
        form.keywords = Self.section("Keywords", in: agentOutput) ?? keywords
        form.releaseNotes = Self.section("Release Notes", in: agentOutput)
            ?? Self.section("Release notes", in: agentOutput)
            ?? releaseNotes
        form.privacyNotes = Self.section("Privacy Questions", in: agentOutput)
            ?? Self.section("Privacy", in: agentOutput)
            ?? privacyNotes
        form.reviewNotes = Self.section("Review Notes", in: agentOutput)
            ?? Self.section("Review notes", in: agentOutput)
            ?? reviewNotes
        return form
    }

    mutating func update(_ field: AppStoreMetadataField, value: String) {
        switch field {
        case .name: name = value
        case .subtitle: subtitle = value
        case .promotionalText: promotionalText = value
        case .description: description = value
        case .keywords: keywords = value
        case .releaseNotes: releaseNotes = value
        case .privacyNotes: privacyNotes = value
        case .reviewNotes: reviewNotes = value
        }
    }

    func value(for field: AppStoreMetadataField) -> String {
        switch field {
        case .name: name
        case .subtitle: subtitle
        case .promotionalText: promotionalText
        case .description: description
        case .keywords: keywords
        case .releaseNotes: releaseNotes
        case .privacyNotes: privacyNotes
        case .reviewNotes: reviewNotes
        }
    }

    private static func keywordFallback(projectName: String, scan: ProjectScanResult?) -> String {
        let base = projectName
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        let capabilityKeywords = scan?.capabilities.map(\.rawValue) ?? []
        return (base + capabilityKeywords + ["productivity", "utility"])
            .map { $0.lowercased() }
            .prefix(8)
            .joined(separator: ", ")
    }

    private static func section(_ label: String, in text: String) -> String? {
        let labels = [
            "subtitle",
            "description",
            "keywords",
            "release notes",
            "review notes",
            "privacy questions",
            "privacy",
            "promotional text",
            "promotional"
        ]
        let normalizedLabel = label.lowercased()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        for index in lines.indices {
            let cleaned = cleanedHeading(lines[index])
            let lowercased = cleaned.lowercased()
            guard lowercased.hasPrefix("\(normalizedLabel):") || lowercased == normalizedLabel else { continue }

            let inlineValue = cleaned
                .dropFirst(label.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespacesAndNewlines))
            if !inlineValue.isEmpty {
                return String(inlineValue)
            }

            let following = lines.dropFirst(index + 1)
                .prefix { line in
                    let lower = cleanedHeading(line).lowercased()
                    return !labels.contains { lower.hasPrefix("\($0):") || lower == $0 }
                }
                .map(cleanedBody)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return following.isEmpty ? nil : following
        }
        return nil
    }

    private static func cleanedHeading(_ value: String) -> String {
        value
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -#`*").union(.whitespacesAndNewlines))
    }

    private static func cleanedBody(_ value: String) -> String {
        value
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t`"))
    }
}

enum ScreenshotAssetField {
    case title
    case caption
    case device
}

struct ScreenshotReviewAsset: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var caption: String
    var device: String
    var visualDirection: String
    var paletteIndex: Int

    static func defaults(projectName: String) -> [ScreenshotReviewAsset] {
        [
            ScreenshotReviewAsset(
                title: "\(projectName) at a glance",
                caption: "Show the first screen users understand in seconds.",
                device: "iPhone 6.7\"",
                visualDirection: "Primary app screen with clean App Store framing.",
                paletteIndex: 0
            ),
            ScreenshotReviewAsset(
                title: "Core workflow",
                caption: "Highlight the action users perform most often.",
                device: "iPhone 6.7\"",
                visualDirection: "A focused in-app moment with concise caption space.",
                paletteIndex: 1
            ),
            ScreenshotReviewAsset(
                title: "Review before release",
                caption: "Show the result, summary, or confirmation state.",
                device: "iPhone 6.7\"",
                visualDirection: "Polished final state with clear benefit-oriented copy.",
                paletteIndex: 2
            )
        ]
    }

    var palette: [Color] {
        GeneratedScreenshotDraft.palettes[paletteIndex % GeneratedScreenshotDraft.palettes.count]
    }

    mutating func update(_ field: ScreenshotAssetField, value: String) {
        switch field {
        case .title: title = value
        case .caption: caption = value
        case .device: device = value
        }
    }
}

enum IAPProductKind: String, CaseIterable, Identifiable, Hashable {
    case autoRenewable = "Subscription"
    case nonConsumable = "One-time unlock"
    case consumable = "Consumable"

    var id: String { rawValue }
}

enum IAPProductField {
    case productID
    case displayName
    case reviewNote
}

struct IAPProductDraft: Identifiable, Hashable {
    var id = UUID()
    var productID: String
    var displayName: String
    var kind: IAPProductKind
    var reviewNote: String

    mutating func update(_ field: IAPProductField, value: String) {
        switch field {
        case .productID: productID = value
        case .displayName: displayName = value
        case .reviewNote: reviewNote = value
        }
    }
}

struct IAPReviewForm: Hashable {
    var isEnabled = false
    var setupNote = "No in-app purchases planned for this release."
    var products: [IAPProductDraft] = []

    static func fallback(scan: ProjectScanResult?) -> IAPReviewForm {
        let detectedStoreKit = scan?.capabilities.contains(.inAppPurchase) == true
        if detectedStoreKit {
            return IAPReviewForm(
                isEnabled: true,
                setupNote: "StoreKit or IAP capability was detected. Review product IDs and pricing before any live App Store Connect change.",
                products: [
                    IAPProductDraft(
                        productID: "premium_monthly",
                        displayName: "Premium Monthly",
                        kind: .autoRenewable,
                        reviewNote: "Confirm subscription benefits, restore purchase behavior, and price before upload."
                    )
                ]
            )
        }
        return IAPReviewForm(
            isEnabled: false,
            setupNote: "No StoreKit/IAP capability was detected. Leave this off unless this release sells digital content.",
            products: []
        )
    }

    func applying(agentOutput: String) -> IAPReviewForm {
        guard isEnabled else { return self }
        var form = self
        if !agentOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            form.setupNote = "IAP draft prepared locally. Review product IDs, pricing, restore behavior, and subscription terms before any App Store Connect change."
        }
        return form
    }
}

struct ReleaseKitState {
    var scanResult: ProjectScanResult?
    var findings: [DiagnosticFinding] = []
    var metadataForm = AppStoreMetadataForm()
    var screenshotAssets: [ScreenshotReviewAsset] = []
    var iapForm = IAPReviewForm()
    var generatedReleasePlan: String?
    var generatedScreenshotDraft: GeneratedScreenshotDraft?
    var generatedMetadataDraft: String?
    var generatedIAPDraft: String?
    var isGeneratingReleasePlan = false
    var isGeneratingScreenshotDraft = false
    var isGeneratingMetadataDraft = false
    var isGeneratingIAPDraft = false
    var isGeneratingReleaseKit = false
    var hasStartedReleaseKit = false
    var releaseKitStatus = "Ready"
    var releasePlanStatus: ReleaseKitSectionStatus = .pending
    var metadataStatus: ReleaseKitSectionStatus = .pending
    var screenshotStatus: ReleaseKitSectionStatus = .pending
    var iapStatus: ReleaseKitSectionStatus = .pending
    var riskStatus: ReleaseKitSectionStatus = .pending
    var appleToolsStatus: ReleaseKitSectionStatus = .pending
    var appleEnvironment: AppleDeveloperEnvironment?
    var appleConnectionState: ConnectionState = .notConnected
    var appleConnectionMessage = "Apple developer environment has not been checked yet."

    var riskDisplayStatus: String {
        switch riskStatus {
        case .ready:
            findings.isEmpty ? "Clear" : "\(findings.count)"
        default:
            riskStatus.rawValue
        }
    }

    var appleToolsDisplayStatus: String {
        switch appleToolsStatus {
        case .ready:
            appleConnectionState.rawValue
        default:
            appleToolsStatus.rawValue
        }
    }
}

enum ReleaseKitGeneratedSection: Sendable {
    case releasePlan(String)
    case metadata(String)
    case screenshots(String)
    case iap(String)
    case appleTools(AppleDeveloperEnvironment)
    case failed(ReleaseKitGeneratedSectionID, String)
}

enum ReleaseKitGeneratedSectionID: Sendable {
    case releasePlan
    case metadata
    case screenshots
    case iap
    case appleTools

    var title: String {
        switch self {
        case .releasePlan: "Release plan"
        case .metadata: "Metadata"
        case .screenshots: "Screenshots"
        case .iap: "Purchases"
        case .appleTools: "Apple tools"
        }
    }

    var phase: WorkflowPhase {
        switch self {
        case .releasePlan: .planning
        case .metadata: .metadata
        case .screenshots: .screenshots
        case .iap: .payments
        case .appleTools: .building
        }
    }
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

    static let palettes: [[Color]] = [
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

struct LaunchKitMainView: View {
    @Bindable var model: LaunchKitAppModel

    var body: some View {
        HStack(spacing: 0) {
            AppListPane(model: model)
                .frame(width: 360)
                .background(.ultraThinMaterial)

            Divider()
                .opacity(0.45)

            ReleaseKitPane(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LaunchKitSurfaceBackground())
        .task {
            await model.bootstrap()
        }
    }
}

struct LaunchKitSurfaceBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.10),
                    Color(nsColor: .windowBackgroundColor).opacity(0.35),
                    Color.black.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

struct LaunchKitGlassCard: ViewModifier {
    var padding: CGFloat = 22
    var radius: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(.primary.opacity(0.07), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.08), radius: 14, y: 8)
    }
}

extension View {
    func launchKitGlassCard(padding: CGFloat = 22, radius: CGFloat = 18) -> some View {
        modifier(LaunchKitGlassCard(padding: padding, radius: radius))
    }
}

struct SectionStatusPill: View {
    let status: String

    var body: some View {
        Text(status)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.thinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

struct LaunchKitPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 24)
            .frame(minHeight: 46)
            .background(
                isEnabled
                    ? Color.accentColor.opacity(configuration.isPressed ? 0.82 : 0.94)
                    : Color.secondary.opacity(0.18),
                in: Capsule()
            )
            .foregroundStyle(.white)
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
            .opacity(isEnabled ? 1 : 0.58)
    }
}

struct LaunchKitPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

struct AppListPane: View {
    @Bindable var model: LaunchKitAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("LaunchKit")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(agentSummary)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if !model.isAIReady {
                LoginRequiredPanel(model: model)
            }

            HStack {
                Text("Apps")
                    .font(.title3.weight(.semibold))
                Spacer()
                if model.isDiscoveringProjects {
                    ProgressView()
                        .scaleEffect(0.65)
                }
            }
            Text("Switch apps anytime. Each app keeps its own generated kit and running progress.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.discoveredProjects.isEmpty {
                ContentUnavailableView(
                    model.isDiscoveringProjects ? "Finding apps" : "No apps found",
                    systemImage: "app.dashed",
                    description: Text(model.isDiscoveringProjects ? "Looking in your developer folders." : "LaunchKit checks ~/code, ~/Developer, and ~/Projects.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.discoveredProjects) { project in
                            AppListRow(
                                project: project,
                                kit: model.releaseKit(for: project),
                                isSelected: model.selectedProject?.id == project.id
                            ) {
                                model.selectProject(project)
                            }
                        }
                    }
                }
            }
        }
        .padding(28)
    }

    private var agentSummary: String {
        if model.isAIReady {
            return "AI ready with \(model.selectedAIProvider.displayName)"
        }
        if model.connectionState(for: model.selectedAIProvider) == .missing {
            return "\(model.selectedAIProvider.displayName) needs installing"
        }
        return "Sign in once to generate release kits"
    }
}

struct LoginRequiredPanel: View {
    @Bindable var model: LaunchKitAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("AI", selection: $model.selectedAIProvider) {
                ForEach(LocalAgentProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)

            Button {
                Task {
                    switch model.connectionState(for: model.selectedAIProvider) {
                    case .missing:
                        await model.installAgent(provider: model.selectedAIProvider)
                    case .connected:
                        break
                    default:
                        await model.connectAI(provider: model.selectedAIProvider)
                    }
                }
            } label: {
                Label(loginTitle, systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isInstallingAgent || model.isLoggingIntoAgent || model.isCheckingAgent)

            Text("Uses your local subscription login. No provider API keys.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var loginTitle: String {
        if model.isInstallingAgent { return "Installing..." }
        if model.isLoggingIntoAgent { return "Opening sign in..." }
        switch model.connectionState(for: model.selectedAIProvider) {
        case .missing: return "Install \(model.selectedAIProvider.displayName)"
        case .connected: return "AI ready"
        default: return "Sign in with \(model.selectedAIProvider.displayName)"
        }
    }
}

struct AppListRow: View {
    let project: DiscoveredProjectCandidate
    let kit: ReleaseKitState
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.primary.opacity(0.08), lineWidth: 1)
                    }
                VStack(alignment: .leading, spacing: 5) {
                    Text(project.name)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                    Text(project.rootURL.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let statusText {
                    Text(statusText)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(statusTint.opacity(0.16), in: Capsule())
                        .foregroundStyle(statusTint)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(LaunchKitPressButtonStyle())
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.25) : .clear, lineWidth: 1)
        }
        .animation(.smooth(duration: 0.18), value: isSelected)
        .animation(.smooth(duration: 0.18), value: statusText)
    }

    private var icon: String {
        switch project.projectType {
        case .swiftPackage: "shippingbox"
        case .reactNative, .flutter, .capacitor: "iphone.gen3"
        default: "app"
        }
    }

    private var statusText: String? {
        if kit.isGeneratingReleaseKit {
            return "Generating"
        }
        if kit.hasStartedReleaseKit {
            return "Ready"
        }
        return nil
    }

    private var statusTint: Color {
        kit.isGeneratingReleaseKit ? .accentColor : .secondary
    }
}

struct ReleaseKitPane: View {
    @Bindable var model: LaunchKitAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let project = model.selectedProject {
                    let kit = model.releaseKit(for: project)
                    SelectedAppHeader(model: model, project: project, kit: kit)
                    ReleaseKitReview(model: model, project: project, kit: kit)
                } else {
                    EmptyAppSelectionView()
                }
            }
            .frame(maxWidth: 1220, alignment: .leading)
            .padding(.horizontal, 44)
            .padding(.vertical, 32)
        }
    }
}

struct EmptyAppSelectionView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Select an app")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
            Text("LaunchKit will generate everything needed for review from one button.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(80)
    }
}

struct SelectedAppHeader: View {
    @Bindable var model: LaunchKitAppModel
    let project: DiscoveredProjectCandidate
    let kit: ReleaseKitState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(project.name)
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                    Text(project.rootURL.path)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Text(project.projectType.rawValue)
                    .font(.callout.weight(.bold))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
            }

            Button {
                Task { await model.generateReleaseKit(for: project) }
            } label: {
                Label(primaryActionTitle, systemImage: kit.isGeneratingReleaseKit ? "sparkles" : "wand.and.sparkles")
                    .font(.headline)
                    .frame(minWidth: 250, minHeight: 44)
            }
            .controlSize(.large)
            .buttonStyle(LaunchKitPrimaryButtonStyle())
            .disabled(!model.isAIReady || kit.isGeneratingReleaseKit)

            if !model.isAIReady {
                Text("Sign in with Codex or Claude Code first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var primaryActionTitle: String {
        kit.isGeneratingReleaseKit ? kit.releaseKitStatus : "Generate Release Kit"
    }
}

struct ReleaseKitReview: View {
    @Bindable var model: LaunchKitAppModel
    let project: DiscoveredProjectCandidate
    let kit: ReleaseKitState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if kit.isGeneratingReleaseKit {
                ProgressPanel(status: kit.releaseKitStatus)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !kit.hasStartedReleaseKit {
                FirstRunPanel()
            } else {
                AppStoreReviewList(model: model, project: project, kit: kit)
                NextActionPanel(model: model, kit: kit)
            }
        }
        .animation(.smooth(duration: 0.22), value: kit.releaseKitStatus)
        .animation(.smooth(duration: 0.22), value: kit.hasStartedReleaseKit)
    }
}

struct ProgressPanel: View {
    let status: String

    var body: some View {
        HStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.15)
            Text(status)
                .font(.title3.weight(.semibold))
            Spacer()
        }
        .launchKitGlassCard(padding: 22, radius: 18)
    }
}

struct FirstRunPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("One click creates the release kit.")
                .font(.title3.weight(.semibold))
            Text("LaunchKit will inspect the app, draft the release plan, metadata, screenshot direction, IAP setup notes, and local Apple readiness, then stop for review.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .launchKitGlassCard()
    }
}

struct AppStoreReviewList: View {
    @Bindable var model: LaunchKitAppModel
    let project: DiscoveredProjectCandidate
    let kit: ReleaseKitState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Review")
                .font(.system(size: 32, weight: .bold, design: .rounded))

            AppStoreReviewSection(
                title: "Release plan",
                description: "Concise generated plan for what happens next.",
                icon: "checklist.checked",
                status: kit.releasePlanStatus.rawValue,
                content: kit.generatedReleasePlan
            )

            EditableSectionHeader(
                title: "Title, subtitle, and positioning",
                description: "These fields map directly to App Store Connect metadata.",
                icon: "textformat",
                status: kit.metadataStatus.rawValue
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    ReviewTextField(label: "Name", text: metadataBinding(.name))
                    ReviewTextField(label: "Subtitle", text: metadataBinding(.subtitle))
                    ReviewTextEditor(label: "Promotional text", text: metadataBinding(.promotionalText), minHeight: 110)
                }
            }

            EditableSectionHeader(
                title: "Description",
                description: "Full App Store description.",
                icon: "doc.text",
                status: kit.metadataStatus.rawValue
            ) {
                ReviewTextEditor(label: "Description", text: metadataBinding(.description), minHeight: 230)
            }

            EditableSectionHeader(
                title: "Keywords",
                description: "Comma-separated search keywords.",
                icon: "number",
                status: kit.metadataStatus.rawValue
            ) {
                ReviewTextField(label: "Keywords", text: metadataBinding(.keywords))
            }

            EditableSectionHeader(
                title: "Release notes",
                description: "What users and reviewers should know about this build.",
                icon: "megaphone",
                status: kit.metadataStatus.rawValue
            ) {
                ReviewTextEditor(label: "Release notes", text: metadataBinding(.releaseNotes), minHeight: 130)
            }

            ScreenshotReviewSection(
                model: model,
                projectID: project.id,
                assets: kit.screenshotAssets,
                status: kit.screenshotStatus.rawValue
            )

            EditableSectionHeader(
                title: "Privacy",
                description: "Answers to review before App Store privacy disclosure.",
                icon: "hand.raised",
                status: kit.metadataStatus.rawValue
            ) {
                ReviewTextEditor(label: "Privacy notes", text: metadataBinding(.privacyNotes), minHeight: 150)
            }

            EditableSectionHeader(
                title: "Review notes",
                description: "Instructions, demo credentials, or reviewer context.",
                icon: "person.text.rectangle",
                status: kit.metadataStatus.rawValue
            ) {
                ReviewTextEditor(label: "Review notes", text: metadataBinding(.reviewNotes), minHeight: 140)
            }

            IAPReviewSection(model: model, projectID: project.id, form: kit.iapForm, status: kit.iapStatus.rawValue)

            AppStoreReviewSection(
                title: "Build, signing, and TestFlight",
                description: "Local Apple tooling readiness before archive and upload.",
                icon: "hammer",
                status: kit.appleToolsDisplayStatus,
                content: kit.appleConnectionMessage
            )

            AppStoreReviewSection(
                title: "Compliance and fixes",
                description: "Issues LaunchKit found that should be fixed or explicitly accepted before submission.",
                icon: "exclamationmark.triangle",
                status: kit.riskDisplayStatus,
                content: complianceText
            )
        }
    }

    private var complianceText: String {
        if kit.riskStatus == .pending {
            return "Waiting for project scan."
        }
        if kit.findings.isEmpty {
            return "No release blockers detected in the current scan."
        }
        return kit.findings
            .map { "\($0.title)\n\($0.recommendedFix ?? $0.explanation)" }
            .joined(separator: "\n\n")
    }

    private func metadataBinding(_ field: AppStoreMetadataField) -> Binding<String> {
        Binding(
            get: {
                model.releaseKit(for: project).metadataForm.value(for: field)
            },
            set: { value in
                model.updateMetadataField(projectID: project.id, field: field, value: value)
            }
        )
    }
}

struct AppStoreReviewSection: View {
    let title: String
    let description: String
    let icon: String
    let status: String
    let text: String?

    init(title: String, description: String, icon: String, status: String, content: String?) {
        self.title = title
        self.description = description
        self.icon = icon
        self.status = status
        self.text = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.title3.weight(.semibold))
                Spacer()
                SectionStatusPill(status: status)
            }
            Text(description)
                .font(.body)
                .foregroundStyle(.secondary)
            Text(displayText)
                .font(.title3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .launchKitGlassCard(padding: 22, radius: 22)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var displayText: String {
        guard let text, !text.isEmpty else { return "Generate the release kit to fill this in." }
        return text
    }
}

struct EditableSectionHeader<Content: View>: View {
    let title: String
    let description: String
    let icon: String
    let status: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.title3.weight(.semibold))
                Spacer()
                SectionStatusPill(status: status)
            }
            Text(description)
                .font(.body)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .launchKitGlassCard(padding: 20, radius: 32)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct ReviewTextField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Text(label)
                .font(.body.weight(.semibold))
                .frame(width: 150, alignment: .leading)
            TextField(label, text: $text)
                .font(.system(size: 18, weight: .medium))
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .padding(.vertical, 2)
    }
}

struct ReviewTextEditor: View {
    let label: String
    @Binding var text: String
    var minHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.body.weight(.semibold))
            TextEditor(text: $text)
                .font(.system(size: 18))
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight)
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.primary.opacity(0.08), lineWidth: 1)
                }
        }
    }
}

struct ScreenshotReviewSection: View {
    @Bindable var model: LaunchKitAppModel
    let projectID: String
    let assets: [ScreenshotReviewAsset]
    let status: String

    var body: some View {
        EditableSectionHeader(
            title: "Images and screenshots",
            description: "Generated screenshot slots. Edit captions, add more, or delete anything you do not want.",
            icon: "photo.on.rectangle",
            status: status
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if assets.isEmpty {
                    Text("No screenshots yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(assets) { asset in
                        ScreenshotAssetRow(model: model, projectID: projectID, asset: asset)
                    }
                }

                Button {
                    model.addScreenshotAsset(projectID: projectID)
                } label: {
                    Label("Add image", systemImage: "plus")
                        .font(.headline)
                        .frame(minHeight: 34)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

struct ScreenshotAssetRow: View {
    @Bindable var model: LaunchKitAppModel
    let projectID: String
    let asset: ScreenshotReviewAsset

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ScreenshotPreviewCard(asset: asset)
                .frame(width: 220, height: 292)

            VStack(alignment: .leading, spacing: 10) {
                ReviewTextField(label: "Title", text: binding(.title))
                ReviewTextField(label: "Caption", text: binding(.caption))
                ReviewTextField(label: "Device", text: binding(.device))
                Text(asset.visualDirection)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity)

            Button {
                model.deleteScreenshotAsset(projectID: projectID, assetID: asset.id)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.bordered)
            .help("Delete image")
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.54), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func binding(_ field: ScreenshotAssetField) -> Binding<String> {
        Binding(
            get: {
                guard let asset = model.releaseKits[projectID]?.screenshotAssets.first(where: { $0.id == self.asset.id }) else {
                    return ""
                }
                switch field {
                case .title: return asset.title
                case .caption: return asset.caption
                case .device: return asset.device
                }
            },
            set: { value in
                model.updateScreenshotAsset(projectID: projectID, assetID: asset.id, field: field, value: value)
            }
        )
    }
}

struct ScreenshotPreviewCard: View {
    let asset: ScreenshotReviewAsset

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: asset.palette,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black.opacity(0.18))
                .frame(width: 118, height: 218)
                .overlay(alignment: .top) {
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .frame(width: 42, height: 5)
                        .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(14)
            VStack(alignment: .leading, spacing: 8) {
                Spacer()
                Text(asset.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                Text(asset.caption)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(4)
            }
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
    }
}

struct IAPReviewSection: View {
    @Bindable var model: LaunchKitAppModel
    let projectID: String
    let form: IAPReviewForm
    let status: String

    var body: some View {
        EditableSectionHeader(
            title: "In-app purchases",
            description: "Simple draft products only. Pricing and live App Store Connect changes still require approval.",
            icon: "creditcard",
            status: status
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Use in-app purchases for this release", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .font(.body.weight(.semibold))
                    .padding(.vertical, 4)

                ReviewTextEditor(label: "Setup note", text: setupNoteBinding, minHeight: 78)

                if form.isEnabled {
                    ForEach(form.products) { product in
                        IAPProductRow(model: model, projectID: projectID, product: product)
                    }

                    Button {
                        model.addIAPProduct(projectID: projectID)
                    } label: {
                        Label("Add product", systemImage: "plus")
                            .font(.headline)
                            .frame(minHeight: 34)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { model.releaseKits[projectID]?.iapForm.isEnabled ?? form.isEnabled },
            set: { model.setIAPEnabled(projectID: projectID, isEnabled: $0) }
        )
    }

    private var setupNoteBinding: Binding<String> {
        Binding(
            get: { model.releaseKits[projectID]?.iapForm.setupNote ?? form.setupNote },
            set: { model.updateIAPSetupNote(projectID: projectID, value: $0) }
        )
    }
}

struct IAPProductRow: View {
    @Bindable var model: LaunchKitAppModel
    let projectID: String
    let product: IAPProductDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(product.displayName)
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    model.deleteIAPProduct(projectID: projectID, productID: product.id)
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.bordered)
                .help("Delete product")
            }

            HStack(spacing: 10) {
                ReviewTextField(label: "Product ID", text: textBinding(.productID))
                ReviewTextField(label: "Display name", text: textBinding(.displayName))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Type")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("Type", selection: kindBinding) {
                        ForEach(IAPProductKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .labelsHidden()
                }
            }

            ReviewTextEditor(label: "Review note", text: textBinding(.reviewNote), minHeight: 70)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.54), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func textBinding(_ field: IAPProductField) -> Binding<String> {
        Binding(
            get: {
                guard let product = model.releaseKits[projectID]?.iapForm.products.first(where: { $0.id == self.product.id }) else {
                    return ""
                }
                switch field {
                case .productID: return product.productID
                case .displayName: return product.displayName
                case .reviewNote: return product.reviewNote
                }
            },
            set: { value in
                model.updateIAPProduct(projectID: projectID, productID: product.id, field: field, value: value)
            }
        )
    }

    private var kindBinding: Binding<IAPProductKind> {
        Binding(
            get: {
                model.releaseKits[projectID]?.iapForm.products.first(where: { $0.id == product.id })?.kind ?? product.kind
            },
            set: { kind in
                model.updateIAPProductKind(projectID: projectID, productID: product.id, kind: kind)
            }
        )
    }
}

struct NextActionPanel: View {
    @Bindable var model: LaunchKitAppModel
    let kit: ReleaseKitState

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Next")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(nextTitle)
                    .font(.headline)
            }
            Spacer()
            Button(nextButtonTitle) {
                model.prepareSafeFixReview()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var nextTitle: String {
        if !kit.findings.isEmpty { return "Review the fixes LaunchKit found" }
        return "Everything generated is ready to review"
    }

    private var nextButtonTitle: String {
        if !kit.findings.isEmpty { return "Review Fixes" }
        return "Continue"
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

                Picker("Local AI provider", selection: $model.selectedAIProvider) {
                    ForEach(LocalAgentProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                    OnboardingStepCard(
                        number: "1",
                        title: "Connect \(model.selectedAIProvider.displayName)",
                        status: model.isCheckingAgent ? "Checking" : model.aiConnectionState.rawValue,
                        bodyText: "LaunchKit uses local subscription auth through \(model.selectedAIProvider.displayName). It does not ask for provider API keys.",
                        buttonTitle: agentButtonTitle(for: model.selectedAIProvider),
                        systemImage: "sparkles"
                    ) {
                        Task {
                            switch model.aiConnectionState {
                            case .missing:
                                await model.installAgent(provider: model.selectedAIProvider)
                            case .connected:
                                await model.refreshAgentStatus(provider: model.selectedAIProvider)
                            default:
                                await model.connectAI(provider: model.selectedAIProvider)
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
            if LocalAgentProvider.allCases.contains(where: { model.authenticationState(for: $0) == nil }) {
                await model.refreshAllAgentStatuses()
            }
        }
    }

    private func agentButtonTitle(for provider: LocalAgentProvider) -> String {
        if model.isInstallingAgent { return "Installing..." }
        if model.isLoggingIntoAgent { return "Opening Login..." }
        switch model.connectionState(for: provider) {
        case .missing: return "Install \(provider.displayName)"
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
            ForEach(LocalAgentProvider.allCases) { provider in
                AgentStatusPanel(model: model, provider: provider)
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

struct AgentStatusPanel: View {
    @Bindable var model: LaunchKitAppModel
    let provider: LocalAgentProvider

    var body: some View {
        StatusPanel(
            title: "\(provider.displayName) Account",
            status: model.connectionState(for: provider).rawValue,
            detail: model.statusMessage(for: provider),
            footnote: model.authenticationState(for: provider)?.executablePath ?? "Install path will appear after detection.",
            actionTitle: actionTitle,
            systemImage: provider == .codex ? "person.crop.circle.badge.checkmark" : "person.crop.circle"
        ) {
            Task {
                switch model.connectionState(for: provider) {
                case .missing:
                    await model.installAgent(provider: provider)
                case .connected:
                    await model.refreshAgentStatus(provider: provider)
                default:
                    await model.connectAI(provider: provider)
                }
            }
        }
    }

    private var actionTitle: String {
        if model.isInstallingAgent { return "Installing..." }
        if model.isLoggingIntoAgent { return "Opening Login..." }
        switch model.connectionState(for: provider) {
        case .missing: return "Install"
        case .connected: return "Recheck"
        case .loginRequired, .failed, .notConnected: return "Open Login"
        case .checking: return "Checking..."
        case .installing: return "Installing..."
        case .limited: return "Open Login"
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
                        Label(model.isGeneratingReleasePlan ? "Generating..." : "Generate With \(model.selectedAIProvider.displayName)", systemImage: "sparkles")
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
                    subtitle: "\(model.selectedAIProvider.displayName) generates screenshot concepts through the local CLI. LaunchKit renders reviewable drafts locally and keeps upload as an approval-gated public-facing action."
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
                    Label(model.isGeneratingMetadataDraft ? "Drafting..." : "Generate With \(model.selectedAIProvider.displayName)", systemImage: "sparkles")
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
                            ("Release Notes", model.generatedReleasePlan ?? "Generate an AI release plan to seed release notes from scan evidence."),
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
                    Label(model.isGeneratingIAPDraft ? "Preparing..." : "Generate IAP Plan With \(model.selectedAIProvider.displayName)", systemImage: "sparkles")
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
            ("AI Plan", "sparkles", model.generatedReleasePlan == nil ? "Generate or review the release plan." : "AI draft is available.", model.generatedReleasePlan == nil ? "Required" : "Ready"),
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
                subtitle: "Codex and Claude Code authentication are owned by their local CLIs. Apple signing material, repository access, and advanced App Store Connect keys stay local by default."
            )
            ForEach(LocalAgentProvider.allCases) { provider in
                StatusPanel(
                    title: "\(provider.displayName) CLI",
                    status: model.connectionState(for: provider).rawValue,
                    detail: model.statusMessage(for: provider),
                    footnote: model.authenticationState(for: provider)?.version ?? "Version unavailable",
                    actionTitle: "Check Status",
                    systemImage: "terminal"
                ) {
                    Task { await model.refreshAgentStatus(provider: provider) }
                }
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
