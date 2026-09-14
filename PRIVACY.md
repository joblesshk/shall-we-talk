# Data handling

This is a description of the source implementation, not a provider privacy policy or a certification.

- Dictation and meeting workflows capture microphone audio with platform permission. Meetings persist audio and text locally; dictation audio retention depends on settings.
- Cloud ASR/cleanup sends audio and/or recognized text to the service selected by the user. The repository supplies no shared API account or hosted relay. Provider retention and billing policies are separate.
- The bundled VAD model runs locally; this does not make the complete transcription pipeline offline.
- API secrets use Keychain. Optional iCloud synchronization uses the developer's configured containers. Users should review sync settings before recording sensitive material.
- macOS insertion uses Accessibility access and the clipboard; iOS keyboard delivery depends on keyboard permissions and current host context. The supplied shortcut copies recognized text to the local clipboard only when nonempty.
- Diagnostics, historical transcripts, audio archives and exports may contain personal data. They are excluded from this GitHub snapshot and must not be submitted in issues without deliberate redaction.

Delete data through the app's supported controls and review provider/iCloud copies separately. Repository access does not grant access to any user's installed app data or private deployment.
