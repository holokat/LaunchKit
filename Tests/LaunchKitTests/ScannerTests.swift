import XCTest
import LaunchKitCore
import LaunchKitScanner

final class ScannerTests: XCTestCase {
    func testDetectsSwiftPackageAndPrivacyFinding() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LaunchKitScannerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "let package = Package(name: \"Example\")".write(
            to: root.appending(path: "Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        let result = try await FileSystemProjectScanner().scan(rootURL: root)

        XCTAssertEqual(result.projectType, .swiftPackage)
        XCTAssertTrue(result.packageManagers.contains(.swiftPackageManager))
        XCTAssertTrue(result.findings.contains { $0.title == "Privacy manifest not found" })
    }

    func testDetectsStoreKitCapability() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LaunchKitStoreKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data().write(to: root.appending(path: "Products.storekit"))

        let result = try await FileSystemProjectScanner().scan(rootURL: root)

        XCTAssertTrue(result.capabilities.contains(.inAppPurchase))
    }
}

