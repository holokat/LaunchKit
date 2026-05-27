# LaunchKit Architecture

LaunchKit is native macOS-first. The durable product shape is:

```text
LaunchKit.app
├─ SwiftUI/AppKit UI
├─ LaunchKitAgent LaunchAgent
│  ├─ workflow queue
│  ├─ repo indexing/watchers
│  ├─ build/screenshot/certificate queues
│  └─ restart recovery
├─ LaunchKitExecutor XPC
│  └─ typed command execution
├─ LaunchKitSecrets XPC
│  └─ Keychain access and JWT/signing operations
└─ LaunchKitApple XPC
   └─ App Store Connect polling and approved mutations
```

The current SwiftPM scaffold implements the core libraries first. A real `.app` project or generated Xcode project is still required for bundled LaunchAgent, XPC service, Sparkle, signing, and notarization packaging.

## Trust Boundaries

- UI presents approvals, diffs, logs, diagnostics, and recovery.
- Agent persists workflow state and schedules jobs, but does not hold secrets or execute arbitrary commands.
- Executor receives typed execution plans, validates policy, streams logs, and enforces checkpoints for writes.
- Secrets module owns Keychain access. Other modules receive references or short-lived outputs.
- App Store Connect writes are remote transactions with before/after snapshots and compensating recovery, not true rollback.

## Action Policy

- Safe read: auto-run.
- Safe reversible write: requires checkpoint and review path.
- Risky write: requires review.
- Public-facing: explicit approval.
- Revenue/legal: explicit approval.
- Destructive: explicit approval and warning.

LLMs may explain, draft, classify, and propose patches. They must never directly execute commands, mutate repos, call remote writes, submit apps, or bypass policy.

