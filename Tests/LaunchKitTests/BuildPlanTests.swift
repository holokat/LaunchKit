import XCTest
import LaunchKitBuild
import LaunchKitCore

final class BuildPlanTests: XCTestCase {
    func testArchivePlanUsesWorkspaceBeforeProject() {
        let scan = ProjectScanResult(
            rootURL: URL(fileURLWithPath: "/tmp/example", isDirectory: true),
            projectType: .nativeXcode,
            xcodeProjects: [DiscoveredFile(path: "Example.xcodeproj", kind: "Xcode project")],
            workspaces: [DiscoveredFile(path: "Example.xcworkspace", kind: "Xcode workspace")]
        )

        let plan = BuildPlanGenerator().makeArchivePlan(
            scan: scan,
            scheme: "Example",
            archivePath: "/tmp/Example.xcarchive"
        )

        XCTAssertEqual(plan.workspacePath, "Example.xcworkspace")
        XCTAssertTrue(plan.commands[0].arguments.contains("-workspace"))
        XCTAssertFalse(plan.commands[0].arguments.contains("-project"))
    }
}
