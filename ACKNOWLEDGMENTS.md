# Design references and acknowledgments

The development research considered the projects below. These are **design/research references**, not a list of runtime dependencies. Existing local research records describe mechanism-level study and independent implementation; this audit did not establish that source code from these projects was copied into the app. Do not infer permission to copy from this acknowledgment. If later code reuse occurs, record the exact revision, license, files and modifications separately.

- [Tinkr-iOS](https://github.com/codewithx55/Tinkr-iOS): host-app recording, keyboard insertion, session identity, acknowledgement and bounded retry mechanisms. No confirmed license permission for source copying was relied on.
- [Diction](https://github.com/DictionLabs/Diction): voice keyboard and service-gateway architecture comparison.
- [Sayboard](https://github.com/stanlsv/sayboard): app/keyboard split and on-device model-management research.
- [TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac): per-app workflows, correction dictionaries and insertion context.
- [VoiceInk](https://github.com/Beingpax/VoiceInk): desktop dictation interaction comparison.
- [Pindrop](https://github.com/watzon/pindrop): searchable dictation history and desktop note workflows.
- [Handy](https://github.com/cjpais/Handy), [Talkink](https://github.com/hasso5703/talkink), [Amical](https://github.com/amicalhq/amical): hotkey dictation, clipboard fallback and context-aware workflows.
- [FluidAudio](https://github.com/FluidInference/FluidAudio): Apple-platform VAD/audio integration research. The separately bundled CoreML VAD model is an actual third-party resource documented in THIRD_PARTY_NOTICES.md.
- [awesome-voice-typing](https://github.com/primaprashant/awesome-voice-typing): discovery of comparable projects.
- [Shortcuts Playground](https://github.com/viticci/shortcuts-playground-plugin): reference for the serialized If-action variable wrapper used in the optional shortcut template. The template's app action descriptor was obtained from this application's existing shortcut, and the result was checked in Apple's Shortcuts editor.

- [KeyboardKit](https://github.com/KeyboardKit/KeyboardKit): keyboard architecture research; no linked SDK dependency in this snapshot.
- [CEGER research paper](https://arxiv.org/abs/2509.14263): contextual speech-recognition correction research reference.

These projects and their contributors are not affiliated with or endorsing Shall We Talk. Their licenses apply to their own materials; this acknowledgment does not change the original application's license.
