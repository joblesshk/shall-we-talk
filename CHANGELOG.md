# Changelog

## Sanitized baseline (2026-09-14)

Based on application version 0.2.0, iOS build 243 and macOS build 18. This is source publication, not a new binary release.

- Background dictation shortcut exposes a text result; conditional system clipboard template included.
- Meeting shortcut uses one action to start/stop recording, verifies received audio, and opens the meeting UI.
- Pending clipboard deliveries have bounded retries and session ownership protection.
- macOS audio engine recreation and native-format exception handling; insertion targeting and original overlay dismissal timing.
- Removed private deployment addresses, local identities and historical operational documents from the publication snapshot. Fresh installs default to user-configured direct API access.
- Added full third-party notices, provenance, configuration, privacy/security and contribution documentation.

See docs/TESTING.md for what was and was not validated. Original internal commit history is intentionally not part of this repository.
