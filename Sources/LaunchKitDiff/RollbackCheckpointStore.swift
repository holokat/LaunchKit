import Foundation
import LaunchKitCore

public struct FileSnapshot: Codable, Hashable, Sendable {
    public var relativePath: String
    public var existed: Bool
    public var sha256: String?
    public var byteCount: Int
    public var postActionSHA256: String?
    public var postActionByteCount: Int?

    public init(
        relativePath: String,
        existed: Bool,
        sha256: String? = nil,
        byteCount: Int = 0,
        postActionSHA256: String? = nil,
        postActionByteCount: Int? = nil
    ) {
        self.relativePath = relativePath
        self.existed = existed
        self.sha256 = sha256
        self.byteCount = byteCount
        self.postActionSHA256 = postActionSHA256
        self.postActionByteCount = postActionByteCount
    }
}

public struct RollbackCheckpoint: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var rootPath: String
    public var action: LaunchKitAction
    public var snapshots: [FileSnapshot]
    public var storagePath: String

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        rootPath: String,
        action: LaunchKitAction,
        snapshots: [FileSnapshot],
        storagePath: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rootPath = rootPath
        self.action = action
        self.snapshots = snapshots
        self.storagePath = storagePath
    }
}

public enum RollbackConflict: Error, LocalizedError, Sendable {
    case currentFileChanged(path: String, expectedHash: String?, actualHash: String?)
    case unsafeRelativePath(String)

    public var errorDescription: String? {
        switch self {
        case let .currentFileChanged(path, expectedHash, actualHash):
            return "Cannot roll back \(path) because it changed after LaunchKit's action. Expected \(expectedHash ?? "missing"), found \(actualHash ?? "missing")."
        case let .unsafeRelativePath(path):
            return "Refusing checkpoint path outside the project: \(path)."
        }
    }
}

public struct RollbackCheckpointStore: Sendable {
    private let baseDirectory: URL

    public init(baseDirectory: URL = RollbackCheckpointStore.defaultBaseDirectory()) {
        self.baseDirectory = baseDirectory
    }

    public func createCheckpoint(
        rootURL: URL,
        action: LaunchKitAction,
        relativePaths: [String]
    ) throws -> RollbackCheckpoint {
        let fileManager = FileManager.default
        try relativePaths.forEach(validateRelativePath)
        let checkpointID = UUID()
        let baseURL = baseDirectory
            .appending(path: checkpointID.uuidString, directoryHint: .isDirectory)
        let filesURL = baseURL.appending(path: "files", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: filesURL, withIntermediateDirectories: true)

        let snapshots = try relativePaths.map { relativePath in
            let source = rootURL.appending(path: relativePath)
            guard fileManager.fileExists(atPath: source.path) else {
                return FileSnapshot(relativePath: relativePath, existed: false)
            }

            let data = try Data(contentsOf: source)
            return FileSnapshot(
                relativePath: relativePath,
                existed: true,
                sha256: SHA256Digest.hexString(for: data),
                byteCount: data.count
            )
        }

        let checkpoint = RollbackCheckpoint(
            id: checkpointID,
            rootPath: rootURL.path,
            action: action,
            snapshots: snapshots,
            storagePath: baseURL.path
        )

        for snapshot in checkpoint.snapshots where snapshot.existed {
            let source = rootURL.appending(path: snapshot.relativePath)
            let destination = filesURL.appending(path: snapshot.relativePath)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
        }

        let manifestURL = baseURL.appending(path: "checkpoint.json")
        let manifestData = try JSONEncoder.launchKit.encode(checkpoint)
        try manifestData.write(to: manifestURL, options: [.atomic])

        return checkpoint
    }

    private func validateRelativePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        if path.hasPrefix("/") || path.isEmpty || components.contains("..") {
            throw RollbackConflict.unsafeRelativePath(path)
        }
    }

    public func restore(_ checkpoint: RollbackCheckpoint) throws {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: checkpoint.rootPath, isDirectory: true)
        let filesURL = URL(fileURLWithPath: checkpoint.storagePath, isDirectory: true)
            .appending(path: "files", directoryHint: .isDirectory)

        for snapshot in checkpoint.snapshots {
            let destination = rootURL.appending(path: snapshot.relativePath)
            if fileManager.fileExists(atPath: destination.path) {
                let currentData = try Data(contentsOf: destination)
                let currentHash = SHA256Digest.hexString(for: currentData)
                if snapshot.existed, currentHash == snapshot.sha256 {
                    continue
                }
                guard let expectedPostActionHash = snapshot.postActionSHA256 else {
                    throw RollbackConflict.currentFileChanged(
                        path: snapshot.relativePath,
                        expectedHash: snapshot.postActionSHA256,
                        actualHash: currentHash
                    )
                }
                guard currentHash == expectedPostActionHash else {
                    throw RollbackConflict.currentFileChanged(
                        path: snapshot.relativePath,
                        expectedHash: expectedPostActionHash,
                        actualHash: currentHash
                    )
                }
            } else if snapshot.postActionSHA256 != nil {
                throw RollbackConflict.currentFileChanged(
                    path: snapshot.relativePath,
                    expectedHash: snapshot.postActionSHA256,
                    actualHash: nil
                )
            }

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }

            guard snapshot.existed else { continue }

            let source = filesURL.appending(path: snapshot.relativePath)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    public func recordPostActionState(_ checkpoint: RollbackCheckpoint) throws -> RollbackCheckpoint {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: checkpoint.rootPath, isDirectory: true)
        var finalized = checkpoint

        finalized.snapshots = try checkpoint.snapshots.map { snapshot in
            var updated = snapshot
            let url = rootURL.appending(path: snapshot.relativePath)
            guard fileManager.fileExists(atPath: url.path) else {
                updated.postActionSHA256 = nil
                updated.postActionByteCount = nil
                return updated
            }

            let data = try Data(contentsOf: url)
            updated.postActionSHA256 = SHA256Digest.hexString(for: data)
            updated.postActionByteCount = data.count
            return updated
        }

        let manifestURL = URL(fileURLWithPath: finalized.storagePath, isDirectory: true)
            .appending(path: "checkpoint.json")
        let manifestData = try JSONEncoder.launchKit.encode(finalized)
        try manifestData.write(to: manifestURL, options: [.atomic])
        return finalized
    }

    public static func defaultBaseDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport
            .appending(path: "LaunchKit", directoryHint: .isDirectory)
            .appending(path: "Checkpoints", directoryHint: .isDirectory)
    }
}
