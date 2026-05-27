import Foundation
import LaunchKitCore

public protocol WorkflowStoring: Sendable {
    func load() async throws -> [ReleaseWorkflow]
    func save(_ workflows: [ReleaseWorkflow]) async throws
}

public actor JSONWorkflowStore: WorkflowStoring {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() async throws -> [ReleaseWorkflow] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.launchKit.decode([ReleaseWorkflow].self, from: data)
    }

    public func save(_ workflows: [ReleaseWorkflow]) async throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.launchKit.encode(workflows)
        try data.write(to: fileURL, options: [.atomic])
    }
}

