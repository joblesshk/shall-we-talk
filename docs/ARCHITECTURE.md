# Architecture

`core/` is a local Swift package: ASR clients, cleanup and edit policies, session ownership, local VAD and testable domain logic. Apple system frameworks provide network, audio, persistence and CoreML capabilities; no third-party Swift package is linked by Package.swift.

`ios/_sources/App` contains the host UI, dictation and meeting coordinators and App Intents. `Shared` contains stores, permissions and cross-extension bridge code. `Keyboard` provides the keyboard and offline dictionary lookup; `LiveActivity` exposes activity state.

`macos/VoicePen` contains the menu-bar app, audio lifecycle, target-field insertion and settings. The Objective-C audio boundary catches exceptions that Swift error handling cannot catch.

Dictation and meetings are separate state machines sharing microphone ownership. Meeting toggle calls the same start/stop lifecycle as UI controls. Keyboard output is bound to a request/document identity. A separate expiring pending clipboard slot avoids delivering old text to a new session.

Local data and provider credentials belong to installed app containers/Keychain, not to the repository. Private relay operations are out of scope for this source snapshot.
