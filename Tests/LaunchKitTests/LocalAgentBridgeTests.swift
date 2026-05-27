import XCTest
import LaunchKitAI

final class LocalAgentBridgeTests: XCTestCase {
    func testClaudeProviderUsesClaudeCodeSubscriptionFlow() {
        XCTAssertEqual(LocalAgentProvider.claude.displayName, "Claude Code")
        XCTAssertEqual(LocalAgentProvider.claude.executableName, "claude")
        XCTAssertEqual(LocalAgentProvider.claude.npmPackageName, "@anthropic-ai/claude-code")
    }

    func testPromptsUseSelectedProviderIdentity() {
        let bridge = LocalAgentBridge()
        let prompt = bridge.releasePlanPrompt(provider: .claude, scan: nil)

        XCTAssertTrue(prompt.contains("Claude.ai-authenticated Claude Code"))
        XCTAssertTrue(prompt.contains("Do not ask for provider API keys."))
    }
}
