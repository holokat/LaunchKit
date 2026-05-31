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

    func testExtractsProductContextForGenerationPrompts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LaunchKitContextTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "ClipPilot")
        """.write(to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        try """
        # ClipPilot
        A clipboard history app for quickly reusing snippets across Mac apps.
        """.write(to: root.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try """
        import SwiftUI
        struct ContentView: View {
            var body: some View {
                Text("Instant clipboard history")
            }
        }
        """.write(to: root.appending(path: "ContentView.swift"), atomically: true, encoding: .utf8)

        let result = try await FileSystemProjectScanner().scan(rootURL: root)

        XCTAssertEqual(result.appContext.preferredDisplayName, "ClipPilot")
        XCTAssertTrue(result.appContext.readmeExcerpts.contains { $0.contains("clipboard history") })
        XCTAssertTrue(result.appContext.sourceStrings.contains("Instant clipboard history"))
        XCTAssertTrue(result.appContext.promptSummary.contains("ClipPilot"))
    }
}
