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
            let appContext = extractAppContext(index: index)
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
                appContext: appContext,
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
        let resolvedRootPath = rootURL.resolvingSymlinksInPath().path
        var paths: [String] = []

        func walk(_ directoryURL: URL) throws {
            let children = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for child in children {
                let childPath = child.resolvingSymlinksInPath().path
                let relativePath = childPath.hasPrefix(resolvedRootPath + "/")
                    ? String(childPath.dropFirst(resolvedRootPath.count + 1))
                    : child.lastPathComponent
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
    if ignoredScanDirectories.contains(basename) {
        return false
    }
    if url.pathExtension == "xcodeproj" || url.pathExtension == "xcworkspace" {
        return false
    }
    return true
}

private let ignoredScanDirectories = Set([
    ".build",
    ".dart_tool",
    ".git",
    ".swiftpm",
    "DerivedData",
    "Pods",
    "build",
    "dist",
    "node_modules",
    "target"
])

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

private func extractAppContext(index: ProjectFileIndex) -> ProjectAppContext {
    var names: [String] = []
    var bundleIdentifiers: [String] = []
    var descriptions: [String] = []
    var readmeExcerpts: [String] = []
    var manifestSignals: [String] = []
    var sourceStrings: [String] = []

    for path in index.relativePaths {
        let basename = URL(fileURLWithPath: path).lastPathComponent
        let lowercased = basename.lowercased()
        let absoluteURL = index.rootURL.appending(path: path)

        if lowercased == "readme.md" || lowercased == "readme" {
            if let readme = readSmallTextFile(absoluteURL) {
                readmeExcerpts.append(contentsOf: readmeProductExcerpts(readme))
            }
        }

        if basename == "Package.swift", let package = readSmallTextFile(absoluteURL) {
            names.append(contentsOf: quotedValues(after: "name:", in: package))
            manifestSignals.append(contentsOf: manifestLines(from: package, prefixes: ["let package", "products:", "dependencies:", ".library", ".executable"]))
        }

        if basename == "package.json", let package = readSmallTextFile(absoluteURL) {
            let parsed = parsePackageJSON(package)
            names.append(contentsOf: parsed.names)
            descriptions.append(contentsOf: parsed.descriptions)
            manifestSignals.append(contentsOf: parsed.signals)
        }

        if basename == "pubspec.yaml", let pubspec = readSmallTextFile(absoluteURL) {
            names.append(contentsOf: yamlValues(for: "name", in: pubspec))
            descriptions.append(contentsOf: yamlValues(for: "description", in: pubspec))
            manifestSignals.append(contentsOf: manifestLines(from: pubspec, prefixes: ["name:", "description:", "dependencies:"]))
        }

        if basename == "Info.plist" {
            let parsed = parseInfoPlist(absoluteURL)
            names.append(contentsOf: parsed.names)
            bundleIdentifiers.append(contentsOf: parsed.bundleIdentifiers)
            manifestSignals.append(contentsOf: parsed.signals)
        }

        if isSourceFile(path), sourceStrings.count < 80, let source = readSmallTextFile(absoluteURL, maxBytes: 90_000) {
            sourceStrings.append(contentsOf: visibleStrings(from: source))
        }
    }

    return ProjectAppContext(
        displayNameCandidates: uniqueCleaned(names).prefixArray(8),
        bundleIdentifiers: uniqueCleaned(bundleIdentifiers).prefixArray(8),
        descriptions: uniqueCleaned(descriptions).prefixArray(8),
        readmeExcerpts: uniqueCleaned(readmeExcerpts).prefixArray(5),
        manifestSignals: uniqueCleaned(manifestSignals).prefixArray(12),
        sourceStrings: uniqueCleaned(sourceStrings).prefixArray(24)
    )
}

private func readSmallTextFile(_ url: URL, maxBytes: Int = 120_000) -> String? {
    guard
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        let size = attributes[.size] as? NSNumber,
        size.intValue <= maxBytes,
        let text = try? String(contentsOf: url, encoding: .utf8)
    else {
        return nil
    }
    return text
}

private func readmeProductExcerpts(_ text: String) -> [String] {
    let lines = text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .filter { !$0.hasPrefix("![") && !$0.hasPrefix("[!") }

    var excerpts: [String] = []
    if let title = lines.first(where: { $0.hasPrefix("#") }) {
        excerpts.append(title.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
    }
    excerpts.append(contentsOf: lines.filter { !$0.hasPrefix("#") }.prefix(4))
    return excerpts.map { clipped($0, maxLength: 240) }
}

private func parsePackageJSON(_ text: String) -> (names: [String], descriptions: [String], signals: [String]) {
    guard
        let data = text.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return ([], [], [])
    }

    var names: [String] = []
    var descriptions: [String] = []
    var signals: [String] = []
    for key in ["displayName", "productName", "name"] {
        if let value = json[key] as? String {
            names.append(value)
            signals.append("\(key): \(value)")
        }
    }
    if let description = json["description"] as? String {
        descriptions.append(description)
        signals.append("description: \(description)")
    }
    if let dependencies = json["dependencies"] as? [String: Any] {
        signals.append("dependencies: \(dependencies.keys.sorted().prefix(12).joined(separator: ", "))")
    }
    return (names, descriptions, signals.map { clipped($0, maxLength: 220) })
}

private func parseInfoPlist(_ url: URL) -> (names: [String], bundleIdentifiers: [String], signals: [String]) {
    guard
        let data = try? Data(contentsOf: url),
        let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    else {
        return ([], [], [])
    }

    var names: [String] = []
    var bundleIdentifiers: [String] = []
    var signals: [String] = []
    for key in ["CFBundleDisplayName", "CFBundleName"] {
        if let value = plist[key] as? String, !value.contains("$(") {
            names.append(value)
            signals.append("\(key): \(value)")
        }
    }
    if let bundleIdentifier = plist["CFBundleIdentifier"] as? String, !bundleIdentifier.contains("$(") {
        bundleIdentifiers.append(bundleIdentifier)
        signals.append("CFBundleIdentifier: \(bundleIdentifier)")
    }
    return (names, bundleIdentifiers, signals)
}

private func quotedValues(after marker: String, in text: String) -> [String] {
    text
        .split(separator: "\n")
        .compactMap { line -> String? in
            guard line.contains(marker) else { return nil }
            let parts = line.split(separator: "\"")
            guard parts.count >= 2 else { return nil }
            return String(parts[1])
        }
}

private func yamlValues(for key: String, in text: String) -> [String] {
    text
        .split(separator: "\n")
        .compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("\(key.lowercased()):") else { return nil }
            return trimmed
                .dropFirst(key.count + 1)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'").union(.whitespacesAndNewlines))
        }
}

private func manifestLines(from text: String, prefixes: [String]) -> [String] {
    text
        .split(separator: "\n")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { line in
            prefixes.contains { line.localizedCaseInsensitiveContains($0) }
        }
        .prefix(8)
        .map { clipped($0, maxLength: 220) }
}

private func isSourceFile(_ path: String) -> Bool {
    let lowercased = path.lowercased()
    return lowercased.hasSuffix(".swift")
        || lowercased.hasSuffix(".m")
        || lowercased.hasSuffix(".mm")
        || lowercased.hasSuffix(".tsx")
        || lowercased.hasSuffix(".jsx")
        || lowercased.hasSuffix(".dart")
}

private func visibleStrings(from source: String) -> [String] {
    let markers = ["Text(", "Label(", "Button(", "navigationTitle(", "NSLocalizedString(", "String(localized:"]
    return source
        .split(separator: "\n")
        .filter { line in markers.contains { line.contains($0) } }
        .flatMap { quotedStringLiterals(in: String($0)) }
        .filter { value in
            value.count >= 3
                && !value.contains("%@")
                && !value.contains("\\(")
                && value.rangeOfCharacter(from: .letters) != nil
        }
        .map { clipped($0, maxLength: 160) }
}

private func quotedStringLiterals(in line: String) -> [String] {
    var values: [String] = []
    var current = ""
    var isInsideQuote = false
    var isEscaped = false

    for character in line {
        if isEscaped {
            current.append(character)
            isEscaped = false
            continue
        }
        if character == "\\" {
            isEscaped = true
            continue
        }
        if character == "\"" {
            if isInsideQuote {
                values.append(current)
                current = ""
            }
            isInsideQuote.toggle()
            continue
        }
        if isInsideQuote {
            current.append(character)
        }
    }
    return values
}

private func uniqueCleaned(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values {
        let cleaned = clipped(
            value
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            maxLength: 260
        )
        guard !cleaned.isEmpty else { continue }
        let key = cleaned.lowercased()
        guard !seen.contains(key) else { continue }
        seen.insert(key)
        result.append(cleaned)
    }
    return result
}

private func clipped(_ value: String, maxLength: Int) -> String {
    guard value.count > maxLength else { return value }
    return String(value.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
}

private extension Array {
    func prefixArray(_ maxLength: Int) -> [Element] {
        Array(prefix(maxLength))
    }
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
