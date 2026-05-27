import XCTest
import LaunchKitCore
import LaunchKitPolicy

final class PolicyEngineTests: XCTestCase {
    func testSafeReadCanRunAutomatically() {
        let action = LaunchKitAction(
            title: "Read project",
            explanation: "Scan files",
            category: .safeRead,
            risk: .informational,
            isReversible: true
        )

        let decision = PolicyEngine().decision(for: action)

        XCTAssertEqual(decision.requirement, .autoRun)
        XCTAssertTrue(decision.canRunAutomatically)
        XCTAssertFalse(decision.requiresRollbackCheckpoint)
    }

    func testRevenueLegalRequiresExplicitApproval() {
        let action = LaunchKitAction(
            title: "Change pricing",
            explanation: "Update subscriptions",
            category: .revenueLegal,
            risk: .critical,
            isReversible: false
        )

        let decision = PolicyEngine().decision(for: action)

        XCTAssertEqual(decision.requirement, .explicitApproval)
        XCTAssertFalse(decision.canRunAutomatically)
        XCTAssertTrue(decision.requiresRollbackCheckpoint)
    }
}

