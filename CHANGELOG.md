# Changelog

## Open-source licensing (2026-09-14)

- License original project code, scripts, documentation and original assets under GPL-3.0-only, with third-party licenses retained.
- Add copyright scope, contribution terms and a licensing guide. This is a licensing/documentation change, not a new binary release.

## Sanitized baseline (2026-09-14)

Based on application version 0.2.0, iOS build 243 and macOS build 18. This is source publication, not a new binary release.

- Background dictation shortcut exposes a text result; conditional system clipboard template included.
- Meeting shortcut uses one action to start/stop recording, verifies received audio, and opens the meeting UI.
- Pending clipboard deliveries have bounded retries and session ownership protection.
- macOS audio engine recreation and native-format exception handling; insertion targeting and original overlay dismissal timing.
- Removed private deployment addresses, local identities and historical operational documents from the publication snapshot. Fresh installs default to user-configured direct API access.
- Added full third-party notices, provenance, configuration, privacy/security and contribution documentation.

See docs/TESTING.md for what was and was not validated. Original internal commit history is intentionally not part of this repository.
