# Apple Platform Boundaries

LaunchKit should be honest about what Apple allows.

## App Store Connect

- Existing apps, builds, TestFlight, screenshots, metadata, IAPs, subscriptions, review submissions, certificates, bundle IDs, and profiles have API coverage.
- New App Store app records still require App Store Connect web flow.
- API keys and role permissions are team/user controlled and can block workflows.
- Some fields are editable only in specific app version states.
- App Review and Beta App Review are asynchronous and opaque.

## Build Uploads

Apple documentation has evolved around build upload APIs, but Xcode/Transporter/altool fallbacks remain necessary. LaunchKit should feature-detect support and keep upload operations approval-gated.

## Signing

- Developer ID certificates are created through Apple Developer website or Xcode.
- Capability changes can invalidate existing provisioning profiles.
- Certificate revocation is team-impacting and destructive.
- `xcodebuild -allowProvisioningUpdates` can mutate Apple Developer state and always needs approval.

## StoreKit/IAP

- Local `.storekit` files are excellent for deterministic tests, but do not upload to App Store Connect.
- Paid Apps Agreement, tax, banking, and first-IAP submission requirements can block automation.
- Product IDs and live subscription state are hard to reverse.

## Assets

- Screenshots and icons are public-facing assets.
- Screenshot sets have strict count, format, display target, and app-version-state constraints.
- App icon changes ship through a new build/version, not a simple metadata upload.

