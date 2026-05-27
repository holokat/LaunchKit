# Testing Strategy

LaunchKit needs four lanes:

1. Fast deterministic unit tests for policy, scanner, planning, secrets references, compliance rules, and rollback.
2. Fixture integration tests using copied mock Apple projects.
3. Local Xcode/simulator E2E tests for builds, xcresult parsing, screenshots, and runtime probes.
4. Remote contract tests with a mock App Store Connect server.

Non-negotiable invariant: LaunchKit must never overwrite user changes silently. Every reversible write needs a visible diff, checkpoint, post-action hash, and rollback conflict behavior.

Current verification:

```bash
swift test
```

