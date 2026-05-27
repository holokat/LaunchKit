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
            home.appending(path: "Projects", directoryHint: .isDirectory),
            home.appending(path: "Documents", directoryHint: .isDirectory)
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

        for child in children {
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true else {
                continue
            }
            guard ![".build", "DerivedData", "Library", "Applications"].contains(child.lastPathComponent) else {
                continue
            }
            candidates.append(child)
        }
        return candidates
    }
}

