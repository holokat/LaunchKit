import Foundation
import LaunchKitCore

public struct DiscoveredProjectCandidate: Codable, Hashable, Sendable, Identifiable {
    public var id: String { rootURL.path }
    public var name: String
    public var rootURL: URL
    public var projectType: ProjectType
    public var xcodeProjects: [DiscoveredFile]
    public var workspaces: [DiscoveredFile]

    public init(
        name: String,
        rootURL: URL,
        projectType: ProjectType,
        xcodeProjects: [DiscoveredFile],
        workspaces: [DiscoveredFile]
    ) {
        self.name = name
        self.rootURL = rootURL
        self.projectType = projectType
        self.xcodeProjects = xcodeProjects
        self.workspaces = workspaces
    }
}

public struct ProjectDiscoveryService: Sendable {
    private let scanner: FileSystemProjectScanner

    public init(scanner: FileSystemProjectScanner = FileSystemProjectScanner()) {
        self.scanner = scanner
    }

    public func discover(searchRoots: [URL]? = nil) async -> [DiscoveredProjectCandidate] {
        let roots = searchRoots ?? defaultSearchRoots()
        var candidates: [DiscoveredProjectCandidate] = []
        var seen = Set<String>()

        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            let childURLs = candidateRoots(under: root)
            for childURL in childURLs where !seen.contains(childURL.path) {
                seen.insert(childURL.path)
                guard looksLikeProjectRoot(childURL) else { continue }
                guard let result = try? await scanner.scan(rootURL: childURL) else { continue }
                guard result.projectType != .unknown else { continue }
                candidates.append(DiscoveredProjectCandidate(
                    name: childURL.lastPathComponent,
                    rootURL: childURL,
                    projectType: result.projectType,
                    xcodeProjects: result.xcodeProjects,
                    workspaces: result.workspaces
                ))
            }
        }

        return candidates.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func defaultSearchRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: "code", directoryHint: .isDirectory),
            home.appending(path: "Code", directoryHint: .isDirectory),
            home.appending(path: "Developer", directoryHint: .isDirectory),
            home.appending(path: "Projects", directoryHint: .isDirectory)
        ]
    }

    private func candidateRoots(under root: URL) -> [URL] {
        let fileManager = FileManager.default
        var candidates = [root]
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return candidates
        }

        for child in children.prefix(160) {
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true else {
                continue
            }
            guard !ignoredDirectoryNames.contains(child.lastPathComponent) else {
                continue
            }
            candidates.append(child)
        }
        return candidates
    }

    private func looksLikeProjectRoot(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        let names = Set(children.map(\.lastPathComponent))
        if !names.isDisjoint(with: projectRootMarkers) {
            return true
        }
        if children.contains(where: { $0.pathExtension == "xcodeproj" || $0.pathExtension == "xcworkspace" }) {
            return true
        }
        if names.contains("ios"),
           let iosChildren = try? fileManager.contentsOfDirectory(
                at: url.appending(path: "ios", directoryHint: .isDirectory),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
           ),
           iosChildren.contains(where: { $0.pathExtension == "xcodeproj" || $0.pathExtension == "xcworkspace" }) {
            return true
        }
        return false
    }
}

private let ignoredDirectoryNames = Set([
    ".build",
    ".git",
    "Applications",
    "DerivedData",
    "Library",
    "node_modules",
    "Pods"
])

private let projectRootMarkers = Set([
    "Package.swift",
    "Podfile",
    "Project.swift",
    "Workspace.swift",
    "project.yml",
    "project.yaml",
    "pubspec.yaml",
    "package.json",
    "capacitor.config.ts",
    "capacitor.config.json"
])
