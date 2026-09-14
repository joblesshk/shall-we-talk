# iOS shortcuts

## Dictation and clipboard

Create: **Voice input** -> **If output has any value** -> **Copy that output to Clipboard** -> **End If**. Start returns empty output; stopping waits for the current result. The template is `ios/Shortcuts/voice-input-copy.plist`; use its README to sign/import it after adjusting bundle/team identifiers for your build.

The text is pasted manually when another input method is active. This shortcut does not automatically open the app for dictation. If background microphone activation is denied, manually open the app and review permissions/standby settings. A result timeout does not erase a recording already being processed. If silence detection has already completed the entire session, running a toggle again can start the next session.

## Meetings

The action displayed as **Start or stop meeting recording** retains the internal identifier `OpenMeetingRecordsIntent` for compatibility. It opens the app and meeting page. Idle starts a meeting; starting/recording/interrupted stops the current one. Ordinary dictation blocks conflicting meeting starts. Audio reception is checked before a success result.

The former **Open meeting records** action was changed to this toggle at the owner's request; it is no longer navigation-only. Test permissions, repeated invocation, interruptions, background recording and saved audio on a physical device.
