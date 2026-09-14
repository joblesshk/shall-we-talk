# Configuration

## Apple build identity

Install Xcode 26+ and XcodeGen. Replace `YOURTEAMID` with your Apple development team in both project definitions. Replace `org.example` bundle identifiers and the related App Group and iCloud container identifiers with identifiers registered to your own account. Keep all targets and entitlements consistent. Regenerate iOS with `scripts/bootstrap.sh`; regenerate macOS with `xcodegen generate --spec macos/project.yml --project macos` after changing its definition.

Unsigned simulator/macOS validation needs no signing account. Device/App Store builds require the appropriate Apple capabilities and provisioning. Do not reuse the previous maintainer's identifiers or credentials.

## Services

Fresh settings select **direct API**. The current product connection UI exposes route selection, not a complete bring-your-own-key form. Developers must provide a secure local provisioning/settings path before live use. On iOS, the existing `MobileSettingsStore.volcAppId`, `volcAccessToken`, `llmKey` and `arkKey` properties are the configuration boundary; secret setters use `KeychainSecretStore`. Do not put values in source or build scripts. The macOS settings store likewise starts with empty credentials. This snapshot builds without credentials but does not provide turnkey service onboarding. Public vendor endpoints are retained for client compatibility, not to supply access. No API secrets are bundled.

Relay support remains available as an optional protocol implementation, but shipped defaults are reserved `.invalid` examples. Configure your own relay endpoints and authentication; the server implementation and private operator infrastructure are not included. Update `RelayConnection` for macOS and the iOS settings defaults as appropriate. Never commit real service configuration in a publication branch.

## Permissions

Microphone is required for recording. macOS Accessibility is required for supported automatic insertion. iOS keyboard full access and host restrictions affect text delivery. Screen capture/PiP and background behavior are OS-dependent. Enable only the capabilities needed for your build and validate on a physical device.

A successful build does not prove provider credentials, background recording, iCloud containers, keyboard insertion or meeting transcription are configured correctly.


The local macOS Mobile Documents mirror name is derived from `CloudHistorySync.containerID` by replacing dots with tildes. Update the Swift container identifier as well as project settings and entitlements when changing identities; the mirror path no longer contains a separate hardcoded container name. A missing/unavailable iCloud container still makes synchronization unavailable and requires device/account validation.
