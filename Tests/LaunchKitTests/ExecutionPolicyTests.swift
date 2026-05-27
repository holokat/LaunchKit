import XCTest
import LaunchKitCore
import LaunchKitExecution

final class ExecutionPolicyTests: XCTestCase {
    func testWritePlanRequiresCheckpointEvenWithApproval() {
        let action = LaunchKitAction(
            title: "Generate privacy manifest",
            explanation: "Write local file",
            category: .safeReversibleWrite,
            risk: .medium,
            isReversible: true
        )
        let plan = ExecutionPlan(
            kind: .plistValidation,
            executable: .plutil,
            arguments: [ValidatedArgument("-lint"), ValidatedArgument("PrivacyInfo.xcprivacy")],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            allowedReadRoots: [URL(fileURLWithPath: "/tmp")],
            action: action
        )

        XCTAssertThrowsError(try CommandPolicyValidator().validate(plan, approvalGranted: true)) { error in
            guard case ExecutionPolicyError.checkpointRequired = error else {
                return XCTFail("Expected checkpointRequired, got \(error)")
            }
        }
    }

    func testSensitiveArgumentsAreRedactedInDisplayCommand() {
        let action = LaunchKitAction(
            title: "Read ASC",
            explanation: "Poll Apple state",
            category: .safeRead,
            risk: .informational,
            isReversible: true
        )
        let plan = ExecutionPlan(
            kind: .transporterUpload,
            executable: .xcrun,
            arguments: [ValidatedArgument("altool"), ValidatedArgument("--apiKey"), ValidatedArgument("SECRET", isSensitive: true)],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            allowedReadRoots: [URL(fileURLWithPath: "/tmp")],
            action: action
        )

        XCTAssertEqual(plan.displayCommand, "/usr/bin/xcrun altool --apiKey <redacted>")
    }
}
