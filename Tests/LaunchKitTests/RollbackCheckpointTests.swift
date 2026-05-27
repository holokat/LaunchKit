import XCTest
import LaunchKitCore
import LaunchKitDiff

final class RollbackCheckpointTests: XCTestCase {
    func testRestoresModifiedFileWhenPostActionHashMatches() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appending(path: "Info.plist")
        try "before".write(to: file, atomically: true, encoding: .utf8)

        let store = RollbackCheckpointStore(baseDirectory: root.appending(path: "checkpoint-store"))
        let checkpoint = try store.createCheckpoint(rootURL: root, action: rollbackAction(), relativePaths: ["Info.plist"])
        try "after".write(to: file, atomically: true, encoding: .utf8)
        let finalized = try store.recordPostActionState(checkpoint)

        try store.restore(finalized)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "before")
    }

    func testRefusesRollbackWhenUserChangedFileAfterAction() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appending(path: "Config.xcconfig")
        try "before".write(to: file, atomically: true, encoding: .utf8)

        let store = RollbackCheckpointStore(baseDirectory: root.appending(path: "checkpoint-store"))
        let checkpoint = try store.createCheckpoint(rootURL: root, action: rollbackAction(), relativePaths: ["Config.xcconfig"])
        try "after".write(to: file, atomically: true, encoding: .utf8)
        let finalized = try store.recordPostActionState(checkpoint)
        try "user edit".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try store.restore(finalized)) { error in
            XCTAssertTrue(error is RollbackConflict)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "user edit")
    }

    func testRemovesCreatedFileWhenPostActionHashMatches() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RollbackCheckpointStore(baseDirectory: root.appending(path: "checkpoint-store"))
        let checkpoint = try store.createCheckpoint(rootURL: root, action: rollbackAction(), relativePaths: ["PrivacyInfo.xcprivacy"])
        let file = root.appending(path: "PrivacyInfo.xcprivacy")
        try "generated".write(to: file, atomically: true, encoding: .utf8)
        let finalized = try store.recordPostActionState(checkpoint)

        try store.restore(finalized)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRejectsPathTraversalCheckpoint() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RollbackCheckpointStore(baseDirectory: root.appending(path: "checkpoint-store"))

        XCTAssertThrowsError(try store.createCheckpoint(rootURL: root, action: rollbackAction(), relativePaths: ["../Secrets.p8"]))
    }

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LaunchKitRollbackTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func rollbackAction() -> LaunchKitAction {
        LaunchKitAction(
            title: "Test write",
            explanation: "Mutate file under checkpoint",
            category: .safeReversibleWrite,
            risk: .medium,
            isReversible: true
        )
    }
}

