#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE_DIR="$(cd "$ROOT/../core" && pwd)"
CORE="$CORE_DIR/Sources/ShallWeTalkCore"
CORE_SCRATCH="${SHALLWETALK_KEYBOARD_CORE_SCRATCH:-/tmp/ShallWeTalk-keyboard-regression-core}"
KEYBOARD="$ROOT/_sources/Keyboard/KeyboardViewController.swift"
KEYBOARD_THEME="$ROOT/_sources/Keyboard/KeyboardTheme.swift"
KEYBOARD_INFO="$ROOT/_sources/Keyboard/Info.plist"
DICTATION="$ROOT/_sources/App/DictationController.swift"
MAC_APP_STATE="$ROOT/../macos/VoicePen/AppState.swift"
MAC_SETTINGS_VIEW="$ROOT/../macos/VoicePen/Settings/SettingsView.swift"
DICTATION_POLICY="$CORE/DictationPolicy.swift"
BRIDGE="$ROOT/_sources/Shared/KeyboardBridgeStore.swift"
QUIET_INK_COMPONENTS="$ROOT/_sources/Shared/QuietInkComponents.swift"
QUIET_INK_PALETTE="$ROOT/_sources/Shared/QuietInkPalette.swift"
QUIET_INK_ASSETS="$ROOT/_sources/Shared/QuietInkAssets.xcassets"
APP_THEME="$ROOT/_sources/Shared/Theme.swift"
APP_ENTRY="$ROOT/_sources/App/VoicePenMobileApp.swift"
APP_INFO="$ROOT/_sources/App/Info.plist"
APP_ICON="$ROOT/_sources/App/Assets.xcassets/AppIcon.appiconset"
APP_ENTITLEMENTS="$ROOT/_sources/App/App.entitlements"
APP_ICLOUD_ENTITLEMENTS="$ROOT/_sources/App/App.iCloud.entitlements"
KEYBOARD_ENTITLEMENTS="$ROOT/_sources/Keyboard/Keyboard.entitlements"
PROJECT="$ROOT/VoicePenMobile.xcodeproj/project.pbxproj"
APP_GROUP="$ROOT/_sources/Shared/AppGroup.swift"
DEFAULT_TEAM_ID="YOURTEAMID"

MEETING_DELETE_SMOKE_BIN="${TMPDIR:-/tmp}/meeting-audio-deletion-smoke-$$"
trap 'rm -f "$MEETING_DELETE_SMOKE_BIN"' EXIT
xcrun swiftc \
  "$ROOT/_sources/Shared/MeetingAudioWriter.swift" \
  "$ROOT/tests/MeetingAudioDeletionSmoke.swift" \
  -o "$MEETING_DELETE_SMOKE_BIN"
"$MEETING_DELETE_SMOKE_BIN"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

grep -Fq 'info?["CFBundleShortVersionString"]' "$MAC_SETTINGS_VIEW" \
  && grep -Fq 'info?["CFBundleVersion"]' "$MAC_SETTINGS_VIEW" \
  && grep -Fq '版本 \(version)（Build \(build)）' "$MAC_SETTINGS_VIEW" \
  || fail "macOS settings must display the installed marketing version and build number"

grep -Fq 'nostream 会话返回空终稿' "$MAC_APP_STATE" \
  && grep -Fq 'raw = try await runASR(wav: wav)' "$MAC_APP_STATE" \
  || fail "macOS must route an empty nostream final through the existing whole-recording fallback"

grep -q "DEVELOPMENT_TEAM: $DEFAULT_TEAM_ID" "$ROOT/project.yml" \
  || fail "project.yml must pin both targets to the placeholder development team"

grep -q "DEVELOPMENT_TEAM = $DEFAULT_TEAM_ID" "$PROJECT" \
  || fail "Xcode project must pin signing to the placeholder development team"

grep -q "<string>voicepen</string>" "$APP_INFO" \
  || fail "App URL scheme voicepen is not registered"

grep -q "VoicePenURL.record" "$KEYBOARD" \
  || fail "Keyboard mic entry must retain the containing-app record URL"

grep -q "makeVoiceEntry" "$KEYBOARD" \
  || fail "Keyboard should render a visible UIKit voice entry, not rely on Link appearance"

# v2 双面键盘:录音胶囊与 Switch 共享 Quiet Ink 波形语言。
test -f "$QUIET_INK_COMPONENTS" \
  || fail "Shared Quiet Ink components are missing"
grep -q "struct QuietInkWaveformTicks" "$QUIET_INK_COMPONENTS" \
  || fail "Main app and keyboard must share the waveform-ticks component"
grep -q "struct QuietInkFaceColumn" "$QUIET_INK_COMPONENTS" \
  || fail "Keyboard face switch column must be a reusable shared component"
grep -q "struct QuietInkRecordButton" "$QUIET_INK_COMPONENTS" \
  && grep -q "enum QuietInkRecordButtonState" "$QUIET_INK_COMPONENTS" \
  || fail "Final five-state record button must be a reusable shared component"
# 2026-08-14 交接稿 v2:63×34 胶囊(两个 29pt 半边)改为两个 58×50 独立键。
# 「整颗切换」这条不变量的前提是半边太小容易点错;58×50 已远超最小命中区,
# 因此改为直接选中,并锁住每个键的实际尺寸。
grep -q "keyHeight: CGFloat = 50" "$QUIET_INK_COMPONENTS" \
  && grep -q "columnWidth: CGFloat = 58" "$QUIET_INK_COMPONENTS" \
  && grep -q "keyCornerRadius: CGFloat = 15" "$QUIET_INK_COMPONENTS" \
  || fail "Face column keys must be 58x50 with 15pt corners"
grep -Fq ".allowsHitTesting(isEnabled)" "$QUIET_INK_COMPONENTS" \
  && grep -Fq ".opacity(isEnabled ? 1 : 0.45)" "$QUIET_INK_COMPONENTS" \
  || fail "Busy-state face column must block taps and dim to 45 percent"
# 语音二次修改-执行方略.md v2 §6.1(2026-08-17):双 tab 键(各自 onSelect(face))
# 改为单一切换键 + 修改键——上键点一下切到另一个面(onSelect(targetFace)),
# 不再是"两个键各选各的面"。同一 58×108 外框内新增的修改键单独校验可用性判据。
grep -Fq "onSelect(targetFace)" "$QUIET_INK_COMPONENTS" \
  || fail "Face column switch key must select the other face, not itself"
grep -Fq "var isModifyEnabled = false" "$QUIET_INK_COMPONENTS" \
  && grep -Fq ".allowsHitTesting(isModifyEnabled)" "$QUIET_INK_COMPONENTS" \
  || fail "Face column modify key must be independently gated from the switch key"
grep -q "QuietInkVoiceControlRecordButton" "$KEYBOARD" \
  && grep -q "enum QuietInkVoiceControlRecordState" "$QUIET_INK_COMPONENTS" \
  || fail "Keyboard voice face must reuse the compact shared record button component"
grep -q "ForEach(0..<7" "$QUIET_INK_COMPONENTS" \
  && grep -q "delays: \\[Double\\] = \\[0, 0.13, 0.26, 0.39, 0.52, 0.21, 0.34\\]" "$QUIET_INK_COMPONENTS" \
  || fail "Recording state must use the seven-bar waveform timing from the handoff"

test -f "$QUIET_INK_PALETTE" \
  || fail "Shared Quiet Ink asset palette is missing"
test -d "$QUIET_INK_ASSETS" \
  || fail "Shared Quiet Ink Asset Catalog is missing"
grep -q "_sources/Shared/QuietInkAssets.xcassets" "$ROOT/project.yml" \
  || fail "Keyboard target must compile the shared Quiet Ink Asset Catalog"
for color in QuietInkCanvas QuietInkCard QuietInkInk QuietInkAccent QuietInkActionAccent \
             QuietInkAccentGlyph QuietInkActionAccentGlyph \
             QuietInkRecordingRed QuietInkSeparator QuietInkKeyboardBackground \
             QuietInkLetterKey QuietInkFunctionKey QuietInkKeyLabel QuietInkVoiceStatusTrack \
             QuietInkVoiceHead QuietInkVoiceHeadGlyph QuietInkVoiceCapsuleTrack \
             QuietInkVoiceDeleteKey QuietInkVoiceSendIdle QuietInkSwitchTrack; do
  test -f "$QUIET_INK_ASSETS/$color.colorset/Contents.json" \
    || fail "Missing Any/Dark asset color set: $color"
  grep -q '"appearances"' "$QUIET_INK_ASSETS/$color.colorset/Contents.json" \
    || fail "Asset color set must include a Dark appearance value: $color"
done

! grep -Fq 'Color(hex:' "$KEYBOARD" "$KEYBOARD_THEME" "$APP_THEME" "$APP_ENTRY" \
  || fail "Quiet Ink view/theme code must not hard-code SwiftUI hexadecimal colors"
! grep -Fq 'UIColor(hex:' "$KEYBOARD" "$KEYBOARD_THEME" "$APP_THEME" "$APP_ENTRY" \
  || fail "Quiet Ink view/theme code must not hard-code UIKit hexadecimal colors"
! grep -Eq '#[0-9A-Fa-f]{6}' "$KEYBOARD" "$KEYBOARD_THEME" "$APP_THEME" "$APP_ENTRY" \
  || fail "Quiet Ink view/theme code must not contain hexadecimal color literals"
grep -q "switch traitCollection.userInterfaceStyle" "$KEYBOARD" \
  || fail "Keyboard Any/Dark assets must follow the extension's actual inherited appearance"
grep -q "view.backgroundColor = .clear" "$KEYBOARD" \
  && grep -q "inputView?.backgroundColor = .clear" "$KEYBOARD" \
  && grep -q "view.isOpaque = false" "$KEYBOARD" \
  && ! grep -q "view.superview?.backgroundColor" "$KEYBOARD" \
  || fail "Keyboard surface must remain transparent so the system input-control material is continuous"

! grep -q "sel_registerName(\"openURL:\")" "$KEYBOARD" \
  || fail "Keyboard must not use the deprecated/private openURL: responder selector"

grep -q "SWTOpenHostURL(url, finish)" "$KEYBOARD" \
  || fail "Cold entry must retain the validated URL fallback when extensionContext rejects opening"

grep -q "AVCaptureDevice.authorizationStatus(for: .audio)" "$DICTATION" \
  || fail "Dictation start must inspect microphone authorization status"

grep -q "case .notDetermined" "$DICTATION" \
  || fail "Dictation start must wait for first microphone authorization"

# 原音归档必须在 ASR 收尾/整段重试之前启动；失败分支仍要等它完成并建档，
# 并让历史页可以播放或手动重识别这份音频。
archive_line="$(grep -n 'let audioArchiveTask = Task { await history.archiveAudio' "$DICTATION" | head -1 | cut -d: -f1)"
recognize_line="$(grep -n 'raw = try await session.finish()' "$DICTATION" | head -1 | cut -d: -f1)"
[ -n "$archive_line" ] && [ -n "$recognize_line" ] && [ "$archive_line" -lt "$recognize_line" ] \
  || fail "Completed WAV archival must start before recognition is finalized"
grep -q "appendFailedRecognition" "$DICTATION" \
  && grep -q "recognitionError: message" "$DICTATION" \
  && grep -q "recognitionFailed ? \"重新识别\"" "$ROOT/_sources/App/Views.swift" \
  || fail "Recognition failures must remain as replayable, retryable history records"

test -f "$BRIDGE" \
  || fail "Keyboard bridge store is missing"

grep -q "KeyboardBridgeSnapshot" "$BRIDGE" \
  || fail "Keyboard bridge must publish a structured snapshot"

grep -q "requestRecording" "$BRIDGE" \
  || fail "Keyboard bridge must support background recording requests"

grep -q "requestStopRecording" "$BRIDGE" \
  || fail "Keyboard bridge must support stop-recording requests from the keyboard"

grep -q "pendingRequestAction" "$BRIDGE" \
  || fail "Keyboard bridge must expose typed recording/stop requests"

grep -q "isAppAwake" "$BRIDGE" \
  || fail "Keyboard bridge must expose app-awake state for no-switch recording"

grep -q "canAcceptDirectKeyboardRequest" "$BRIDGE" \
  || fail "Keyboard bridge must only skip app launch when the app recently acknowledged bridge requests"

grep -q "snapshot.canStartRecordingInBackground == true" "$BRIDGE" \
  || fail "A fresh app heartbeat alone must not cause a cold recording request to require two taps"

grep -q "canStartRecordingInBackground: canStartRecordingInBackground" "$DICTATION" \
  || fail "App bridge state must distinguish cold state from hot/PiP background recording capability"

grep -q "KeyboardBridgeStore.effectivePhase(snapshot)" "$KEYBOARD" \
  || fail "Keyboard must expire stale recording/processing state after the main app dies"

grep -q "directStopAvailable = effectiveSnapshot.phase == .recording || effectiveSnapshot.phase == .processing" "$KEYBOARD" \
  || fail "Keyboard must only hide the app-opening Link for fresh in-place stop/progress states"

grep -q "voiceEntryHost?.view.isHidden = recording || processing || alive" "$KEYBOARD" \
  || fail "Personal-team fallback must avoid switching apps when the main app is already alive"

grep -q "DarwinBridge.post(DarwinBridge.cmdStart)" "$KEYBOARD" \
  || fail "Keyboard must ask an already-alive background app to start without switching apps"

grep -q "preparePlainPasteboardFallback" "$KEYBOARD" \
  || fail "Keyboard must watch pasteboard changes after recording requests and stops"

grep -q "UIPasteboard.general.changeCount" "$KEYBOARD" \
  || fail "Keyboard plain pasteboard fallback must be guarded by pasteboard change count"

! grep -q "plainPasteboardBaselineString\|UIPasteboard.general.string" "$KEYBOARD" \
  || fail "Keyboard must not read universal clipboard text during ordinary editing/polling"

grep -q "guard let until = plainPasteboardFallbackUntil" "$KEYBOARD" \
  || fail "Keyboard may inspect clipboard contents only inside an explicit post-dictation fallback window"

grep -q 'pendingTextPayload.v2' "$ROOT/_sources/Shared/PendingTextStore.swift" \
  || fail "Pending text must publish text/request/time as one versioned payload"
grep -q 'LOCK_EX | LOCK_NB' "$ROOT/_sources/Shared/PendingTextStore.swift" \
  || fail "Pending text delivery must use a nonblocking cross-process lock"
grep -q 'removePayload(ifMatching: payload' "$ROOT/_sources/Shared/PendingTextStore.swift" \
  || fail "Pending text acknowledgement must delete only the exact payload inserted"
grep -q 'return .busy' "$ROOT/_sources/Shared/PendingTextStore.swift" \
  || fail "A busy delivery lock must preserve the payload for a later keyboard poll"
grep -q 'PendingTextStore.consume(' "$KEYBOARD" \
  || fail "Keyboard insertion must run inside the transactional pending-text consumer"
! grep -q 'PendingTextStore.pop(' "$KEYBOARD" \
  || fail "Keyboard must not clear pending text before the host accepts insertion"

# Action Button 只在 Shall We Talk 键盘仍处于起录时的同一宿主输入文档时直接插入。
grep -q 'publishKeyboardPresence' "$KEYBOARD" \
  && grep -q 'textDocumentProxy.documentIdentifier' "$KEYBOARD" \
  || fail "Keyboard must publish a short-lived heartbeat bound to its host input document"
grep -q 'activeKeyboardInsertionTarget' "$DICTATION" \
  && grep -q 'publishActionKeyboardDelivery' "$DICTATION" \
  || fail "Action capture must lock and revalidate the active Shall We Talk keyboard target"
grep -q 'pendingActionKeyboardDelivery(for: documentID)' "$KEYBOARD" \
  && grep -q 'drainPendingText(expectedRequestID: requestID)' "$KEYBOARD" \
  || fail "Keyboard must transactionally insert only Action results addressed to its current document"
grep -q 'copyToSystemPasteboard(deliveryText)' "$DICTATION" \
  || fail "Action direct insertion must retain a plain-text clipboard fallback"

# 修改结果必须先清空当前输入框再插入；删除失败时绝不能退化为追加新句。
grep -q 'private func applyEditReplacement' "$KEYBOARD" \
  && grep -q 'textDocumentProxy.deleteBackward()' "$KEYBOARD" \
  && grep -q 'textDocumentProxy.insertText(replacement)' "$KEYBOARD" \
  || fail "Voice edit must clear the host text before inserting the replacement"
! grep -q '放弃删除,直接插入新稿\|撞硬上限.*直接插入新稿' "$KEYBOARD" \
  || fail "Voice edit must never append the new result after a failed replacement"
grep -Fq 'UIPasteboard.general.items = [["public.utf8-plain-text": newText]]' "$KEYBOARD" \
  && grep -q '修改失败,新稿已复制' "$KEYBOARD" \
  || fail "Voice edit must copy the replacement to the clipboard when clearing fails"

! grep -q "preparePlainPasteboardFallback(duration: 3, requiresChange: false)" "$KEYBOARD" \
  || fail "Darwin result events must not reopen an unguarded plain pasteboard fallback window"

! grep -q "voiceEntryHost?.view.isHidden = canSendDirectly || directRequestInFlight" "$KEYBOARD" \
  || fail "Keyboard must not start recording directly from a merely-awake background app"

grep -q "pollBridge" "$KEYBOARD" \
  || fail "Keyboard must poll bridge state while visible"

grep -q "requestStopRecording" "$KEYBOARD" \
  || fail "Keyboard mic button must become a stop button while recording"

# 录音中保留桥接状态与停止语义；单行录音键使用七道波形，整理中使用灰墨三点。
grep -q "KeyboardTheme.recordingRed" "$KEYBOARD" \
  || fail "Keyboard recording state must show the Quiet Ink recording-red status dot"
grep -q "case .processing:" "$KEYBOARD" \
  && grep -q "capsuleState = .processing" "$KEYBOARD" \
  || fail "Keyboard processing state must drive the compact record key"
grep -q "visibleVoiceButton?.isEnabled = state != .processing" "$KEYBOARD" \
  || fail "Keyboard voice button must be physically disabled while text is processing"
grep -q "voiceDeleteButton.addTarget(self, action: #selector(voiceDeleteBackward)" "$KEYBOARD" \
  && grep -q "voiceDeleteButton.isEnabled = true" "$KEYBOARD" \
  && grep -q "@objc private func voiceDeleteBackward()" "$KEYBOARD" \
  && grep -q "textDocumentProxy.deleteBackward()" "$KEYBOARD" \
  && ! grep -q "voiceDeleteButton.addTarget(self, action: #selector(deleteBackward)" "$KEYBOARD" \
  || fail "Voice delete must always use its dedicated direct host-text deletion path"
grep -q "Theme.processingGradient" "$ROOT/_sources/App/DesignSystem.swift" \
  || fail "App record button must use the dedicated processing-disabled color"
grep -q ".disabled(isProcessing)" "$ROOT/_sources/App/DesignSystem.swift" \
  || fail "App record button must be disabled while text is processing"

# 2026-08-26:文案只保留在紧凑录音键内部，语音面不再绘制顶部提示卡。
grep -q '"录音"' "$QUIET_INK_COMPONENTS" \
  && grep -q '"整理中"' "$QUIET_INK_COMPONENTS" \
  || fail "Compact voice row must expose the idle and processing captions"

grep -q "plainPasteboardFallbackUntil" "$KEYBOARD" \
  || fail "Keyboard must briefly allow plain pasteboard fallback after Darwin result events"

grep -q "allowPlainTextFallback" "$ROOT/_sources/Shared/PendingTextStore.swift" \
  || fail "PendingTextStore must support plain text pasteboard fallback when marker metadata is unavailable"

grep -q "resultRequestID" "$BRIDGE" \
  || fail "Keyboard results must be bound to the request that produced them"
grep -q "expectedRequestID: expectedRequestID" "$KEYBOARD" \
  || fail "Keyboard must only consume pending text matching the current bridge result request"
grep -q "if mode == .keyboard" "$DICTATION" \
  && grep -q "PendingTextStore.push(deliveryText, requestID: requestID)" "$DICTATION" \
  || fail "Standalone App dictation must never publish text into the keyboard delivery slot"

grep -Fq 'keyboardHeaderContent.addSubview(candidateScroll)' "$KEYBOARD" \
  || fail "Pinyin candidates must occupy the fixed top-left header region"
grep -Fq 'candidateScroll.leadingAnchor.constraint(equalTo: keyboardHeaderContent.leadingAnchor)' "$KEYBOARD" \
  || fail "Candidate choices must always begin at the same fixed leading position"
! grep -q "compositionLabel" "$KEYBOARD" \
  || fail "Typed pinyin must not be repeated inside the candidate bar"
grep -q "private static let maxVisibleCandidates = 6" "$KEYBOARD" \
  || fail "Candidate bar must stay limited to a small stable set of choices"
grep -q "candidateScroll.backgroundColor = KeyboardTheme.background" "$KEYBOARD" \
  && grep -q "candidateScroll.isOpaque = true" "$KEYBOARD" \
  || fail "Candidate bar must use an opaque surface so the host keyboard material cannot wash out choices"
for edge in top bottom left right; do
  grep -Fq "candidateScroll.${edge}EdgeEffect.isHidden = true" "$KEYBOARD" \
    || fail "Candidate bar must hide the ${edge} system scroll edge effect"
done
grep -q "textDocumentProxy.setMarkedText" "$KEYBOARD" \
  && grep -q "textDocumentProxy.unmarkText()" "$KEYBOARD" \
  || fail "Pinyin composition must appear as marked text in the host input field"

# v2:字母面不再有语音按键；88×88 圆键只存在于专门语音面。
grep -q "activeFace: QuietInkKeyboardFace = .voice" "$KEYBOARD" \
  || fail "Keyboard must open on the dedicated voice face"
# 2026-08-26:旧 108pt 卡片改为单行五键的 52pt 录音键，宽度由五键行弹性分配。
! grep -q "container.widthAnchor.constraint(equalToConstant: 88)" "$KEYBOARD" \
  || fail "Record key width must stretch with the panel, not be pinned to the old 88pt circle"
grep -q "equalToConstant: QuietInkVoiceControlRecordButton.height" "$KEYBOARD" \
  || fail "Record key must take its fixed height from the compact shared component"
grep -q "addLetterRows(to: letters)" "$KEYBOARD" \
  || fail "Keyboard face must contain the full QWERTY letter rows"
grep -q "addSymbolRows(to: symbols)" "$KEYBOARD" \
  && grep -q 'configuration.title = keyboardCharacterPage == .letters ? "123" : "ABC"' "$KEYBOARD" \
  || fail "Keyboard face must provide a 123/ABC numbers-and-punctuation page"
! grep -q "makeActionRow" "$KEYBOARD" \
  || fail "QWERTY face must not retain the old inline voice action row"

# ★冷启动跳转依赖:Link 覆盖层必须贴录音键的扩展热区
grep -q "host.view.leadingAnchor.constraint(equalTo: visualButton.leadingAnchor)" "$KEYBOARD" \
  && grep -q "host.view.trailingAnchor.constraint(equalTo: visualButton.trailingAnchor)" "$KEYBOARD" \
  && grep -q "host.view.topAnchor.constraint(equalTo: visualButton.topAnchor)" "$KEYBOARD" \
  && grep -q "host.view.bottomAnchor.constraint(equalTo: visualButton.bottomAnchor)" "$KEYBOARD" \
  || fail "Cold-start Link overlay must cover the expanded record-key hit area"

# 字母面空格键回归纯空白，不再兼任状态提示条；点击仍插空格。
! grep -q "title: \"空格\"" "$KEYBOARD" \
  || fail "Space key must not render the 空格 title"
grep -q "configureButton(spaceButton, title: nil, symbol: nil, style: .key)" "$KEYBOARD" \
  || fail "Space key must remain a visually blank ordinary key"
grep -q "action: #selector(insertSpace)" "$KEYBOARD" \
  || fail "Space key must still insert a space on tap"
grep -q "layoutButton.widthAnchor.constraint(equalToConstant: 46)" "$KEYBOARD" \
  && grep -q "langButton.widthAnchor.constraint(equalToConstant: 52)" "$KEYBOARD" \
  && grep -q "sendButton.widthAnchor.constraint(equalToConstant: 64)" "$KEYBOARD" \
  || fail "Keyboard bottom bar must keep the reviewed layout/language/send widths"
grep -q "bottomBar.isHidden = voiceSelected" "$KEYBOARD" \
  && ! grep -q "voiceStatusTrack" "$KEYBOARD" \
  || fail "Final voice face must remove the old globe/space/status bottom bar"

grep -q "candidateScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)" "$KEYBOARD" \
  || fail "Pinyin candidate scroll view should expand across the shared row"

! grep -q "stack.addArrangedSubview(makeCandidateBar())" "$KEYBOARD" \
  || fail "Pinyin candidate UI must not add a separate row that shifts the keyboard"

# 2026-08-26:语音面切换键并入单行五键，字母面仍保留顶栏切换胶囊。
grep -q "voiceSwitchButton" "$KEYBOARD" \
  && grep -q "button.widthAnchor.constraint(equalToConstant: 46)" "$KEYBOARD" \
  && grep -q "button.heightAnchor.constraint(equalToConstant: 48)" "$KEYBOARD" \
  || fail "Voice face switch must use the 46x48 single-row control key"
! grep -q "separator.trailingAnchor.constraint(equalTo: switchHost.view.leadingAnchor" "$KEYBOARD" \
  || fail "v2 top row must remain seamless without a divider beside the face switch"
grep -q "CGAffineTransform(scaleX: 0.98, y: 0.98)" "$KEYBOARD" \
  && grep -q "withDuration: 0.22" "$KEYBOARD" \
  || fail "Face changes must crossfade with a subtle scale"
grep -q "leftFunctionButton.widthAnchor.constraint(equalToConstant: 46)" "$KEYBOARD" \
  && grep -q "sendButton.widthAnchor.constraint(equalToConstant: 64)" "$KEYBOARD" \
  || fail "QWERTY face must preserve its fixed bottom function and send zones"
! grep -q "voiceGlobeButton" "$KEYBOARD" \
  && ! grep -q "advanceToNextInputMode()" "$KEYBOARD" \
  || fail "Voice face must rely only on the iOS-hosted bottom input-mode switch"

# v2 每一面各用一个固定高度盒子，**同一面内的状态切换不得跳高**。
# 2026-08-03:高度由写死的 291 改为 Self.keyboardHeight(当时 277,整块键盘下移 14pt;
# 2026-08-13 跟随 iOS 27 的 +2pt 改为 279)。
# 2026-08-14:原断言锁的是"两面共用同一个常量"。该不变量按用户决定作废——语音面的中间结果
# 改为直接写进宿主输入框(marked text)后,顶部品牌行与实时文字区都没有存在意义,语音面被压到
# voiceKeyboardHeight(150),字母面仍需候选栏 + 三排键,压不得。用户明确接受"切面时跳高一次"。
# 仍然要守住的是另一半:**高度只能取这两个具名常量之一**。一旦允许按内容或按 phase 算高,
# 录音/整理过程中键盘就会自己抖动,宿主也要跟着反复重排——那是 §11.2 遮挡问题的老路。
grep -q "private static let keyboardHeight: CGFloat" "$KEYBOARD" \
  && grep -q "keyboardHeight: CGFloat = 279" "$KEYBOARD" \
  && grep -q "private static let voiceKeyboardHeight: CGFloat" "$KEYBOARD" \
  && grep -q "view.heightAnchor.constraint(equalToConstant: currentKeyboardHeight)" "$KEYBOARD" \
  && grep -q "equalTo: view.bottomAnchor" "$KEYBOARD" \
  || fail "Each face must size itself from a fixed named height constant"

# 文字面不得因为语音面的压缩而缩放；279pt、45pt 键高和 11pt 行距共同保证原有 26 键布局完整可见。
grep -q "return Self.keyboardHeight" "$KEYBOARD" \
  && grep -q "letterKeyHeight: CGFloat = 45" "$KEYBOARD" \
  && grep -q "letterRowSpacing: CGFloat = 11" "$KEYBOARD" \
  || fail "Text keyboard must keep its original full-size geometry"

# 高度只能有一个来源:currentKeyboardHeight，且只能经统一函数同步
# Auto Layout 约束与 UIInputView 的固有高度。
# 2026-08-14 的实际事故:resyncKeyboardHeight 写死了 Self.keyboardHeight,于是在 100pt 的
# 语音面上把高度推成字母面的 279,表现为"切到语音键盘时上下伸展一下"。上一版守卫只数了
# `keyboardHeightConstraint?.constant =` 这一种写法,漏掉了经局部变量赋值的那两处。
# 现在改成:所有调用方都经 applyKeyboardHeight，不再各自改约束。
grep -q "private var currentKeyboardHeight: CGFloat" "$KEYBOARD" \
  && grep -q "return Self.voiceKeyboardHeight" "$KEYBOARD" \
  && grep -q "return Self.keyboardHeight" "$KEYBOARD" \
  || fail "Keyboard height must come from a single currentKeyboardHeight source of truth"
height_writes="$(grep -cE "(keyboardHeightConstraint\?|constraint)\.constant = " "$KEYBOARD")"
[ "$height_writes" -eq 1 ] \
  && grep -q "private func applyKeyboardHeight" "$KEYBOARD" \
  && grep -q "constraint.constant = height" "$KEYBOARD" \
  || fail "Every keyboard-height write must go through applyKeyboardHeight"

# resync 在正常几何下跳过。iOS 27 Beta 切换后的顶部空白位于
# 扩展根视图之外(FB24460699)，用 1pt 抖动扩展高度无法消除，不得保留该副作用。
# 判据必须是 viewH/inputH/supH 三者与目标高度一致。**不能**用 winY+winH==screenH——
# 2026-08-14 实测:键盘扩展里 winY 恒为 0,健康态下 gap 也恒等于 screenH-winH,该判据永远为假。
grep -q "resync-skip" "$KEYBOARD" \
  && grep -q "settled(geometry.viewH) && settled(geometry.inputH) && settled(geometry.supH)" "$KEYBOARD" \
  || fail "resyncKeyboardHeight must skip the nudge once viewH/inputH/supH all match the target"

grep -q 'resyncKeyboardHeight(reason: "appear")' "$KEYBOARD" \
  && ! grep -q "applyKeyboardHeight(target - 1)" "$KEYBOARD" \
  && grep -q "UIView.performWithoutAnimation" "$KEYBOARD" \
  && grep -q "preferredContentSize = CGSize" "$KEYBOARD" \
  && grep -q "FB24460699" "$KEYBOARD" \
  || fail "Keyboard must resync only its own geometry and must not nudge the inaccessible iOS 27 host gap"

# “外框变大”也可能是五个控件被缩小造成的相对错觉。真机几何日志必须同时记录
# 容器、安全区、每颗键的实际 frame 和五键并集的上下余量，否则只看 viewH 无法判定。
grep -q "var switchKey = CGRect.zero" "$KEYBOARD" \
  && grep -q "var recordKey = CGRect.zero" "$KEYBOARD" \
  && grep -q "var controlsUnion = CGRect.zero" "$KEYBOARD" \
  && grep -q "safeTop = view.safeAreaInsets.top" "$KEYBOARD" \
  && grep -q "frameInKeyboard(voiceEntryContainer)" "$KEYBOARD" \
  && grep -q "padTB=" "$KEYBOARD" \
  || fail "Keyboard diagnostics must distinguish a larger host frame from shrunken voice controls"

# 2026-08-06:宿主输入框被键盘概率性遮挡的两处根因,都必须钉死。
# ① `UIInputView.allowsSelfSizing` 默认 false,不打开的话我们的高度约束只管内部排布,
#    系统发给宿主的键盘 frame 与实际渲染高度可能对不上。
# ② 高度约束不得是 required:系统自己也往 input view 上挂高度约束,两条 required 冲突时
#    Auto Layout 断哪条不确定,断掉我们这条的那一轮就会让宿主按错误高度布局。
grep -q "inputView?.allowsSelfSizing = true" "$KEYBOARD" \
  || fail "Keyboard must opt into self-sizing, or the host receives a height that differs from what renders"

grep -q "keyboardHeightConstraint.priority = UILayoutPriority(999)" "$KEYBOARD" \
  || fail "Keyboard height constraint must not be required — a conflict with the system constraint breaks it nondeterministically"

grep -q "final class VoicePenSizingInputView: KeyboardTouchInputView" "$KEYBOARD" \
  && grep -q "class KeyboardTouchInputView: UIInputView" "$ROOT/_sources/Keyboard/KeyFieldStackView.swift" \
  && grep -q "override var intrinsicContentSize" "$KEYBOARD" \
  && grep -q "sizingInputView?.contentHeight = height" "$KEYBOARD" \
  || fail "Keyboard input view must publish the active face's fixed intrinsic height"

# 2026-08-26:语音面板不再保留顶部实时文字/提示卡，单行控制区直接顶到语音面顶部。
! grep -q "轻点录音键开始说话" "$KEYBOARD" \
  || fail "Voice face must not render the removed tap-to-record prompt"
! grep -q "liveTextBox\|voiceTextCard\|setVoiceLiveText\|liveLabel" "$KEYBOARD" \
  || fail "Voice face must not retain the removed live text card"

grep -q "voice.backgroundColor = .clear" "$KEYBOARD" \
  && grep -q "controlRow.backgroundColor = .clear" "$KEYBOARD" \
  && grep -q "button.layer.borderWidth = 0" "$KEYBOARD" \
  && ! grep -q "button.layer.borderWidth = 1" "$KEYBOARD" \
  || fail "Voice controls must sit directly on the host background without extra rings"

# 分发包不得携带 API token。LocalSecrets 可以是开发者本机遗留文件，但 XcodeGen 必须排除它，
# 设置中的 token 必须通过 KeychainSecretStore 保存。
if git -C "$ROOT/.." ls-files --error-unmatch ios/_sources/Shared/LocalSecrets.swift >/dev/null 2>&1; then
  fail "LocalSecrets.swift must never be tracked by git"
fi

grep -q "KeychainSecretStore" "$ROOT/_sources/Shared/MobileSettingsStore.swift" \
  || fail "API tokens must be stored in KeychainSecretStore"

grep -A2 "path: _sources/Shared" "$ROOT/project.yml" | grep -q "LocalSecrets.swift" \
  || fail "XcodeGen must exclude LocalSecrets.swift from distribution builds"

# 2026-08-08:结束 Live Activity **不得**靠 App 自己 sleep 再 end。App 在那段睡眠里被
# 挂起,end() 就永远不执行,卡片以 active 状态泄漏在系统里。build 114 让 App 全程留在后台
# 之后这成了常态 —— 多张实时活动并存时灵动岛不给常驻紧凑态,只剩提示动画。
# 用 dismissalPolicy: .after 把延时交给系统:end 立刻登记,之后 App 死活都不影响。
LIVE_ACTIVITY_CTRL="$ROOT/_sources/App/CaptureLiveActivityController.swift"
if grep -A3 "activity.update(content, alertConfiguration: alert)" "$LIVE_ACTIVITY_CTRL" | grep -q "Task.sleep"; then
  fail "Live Activity must not sleep before end(); a suspended app leaks the activity forever"
fi

grep -q "dismissalPolicy: .after" "$LIVE_ACTIVITY_CTRL" \
  || fail "Live Activity dismissal delay must be handed to the system via .after"

grep -A18 "func begin() async" "$LIVE_ACTIVITY_CTRL" | grep -q "await activity.end" \
  || fail "begin() must await stale-activity cleanup before requesting a new one"

# 2026-08-08:捕捉路径的「录完 → 识别整理 → 入库」必须自己持有后台执行凭证。
# recorder.stop() 会停用 AVAudioSession,录音期间那份凭证随之消失,而后面还有几个网络请求。
# build 114 去掉预判性前台化后 App 真的留在后台,这一段就被系统挂起,表现为卡在「正在识别」。
grep -q "func beginCaptureBackgroundWindow" "$DICTATION" \
  || fail "Capture post-processing must hold its own background task assertion"

grep -A12 "private func finish() async {" "$DICTATION" | grep -q "beginCaptureBackgroundWindow()" \
  || fail "The capture background window must open at the top of finish(), before any await"

grep -A18 "private func finish() async {" "$DICTATION" | grep -q "endCaptureBackgroundWindow()" \
  || fail "The capture background window must be closed on every exit path (defer)"

# 2026-08-07:操作按钮的"再按一次停止"必须看**实时状态**,不能只看跨进程标记。
# 标记会被 VAD 自动停清掉,而用户往往正是在"说完停顿一下、VAD 刚停"的一两秒里按停止键;
# 只看标记会把这一按判成"开始新一段",新一段又撞上正在识别的上一段拿不到样本,触发前台
# 重试把 App 顶出来 —— 用户看到的就是"按了没用,只能进 App 手动停"。
grep -q "actionCaptureLiveState" "$ROOT/_sources/App/ActionCaptureIntent.swift" \
  || fail "Action button stop must consult live phase, not just the cross-process flag"

grep -q "if live.processing" "$ROOT/_sources/App/ActionCaptureIntent.swift" \
  || fail "A press while the previous capture is still being processed must be ignored, not restarted"

# 2026-08-06:操作按钮录音期间灵动岛必须一直显示"正在录音"。
# ① 计时器区间上界必须有界 —— Date.distantFuture(公元 4001)会让这一格渲染不出东西,
#    灵动岛看着就像没显示;② 卡片掉了要能自愈,消失路径不止一条,逐条堵不如让目标状态自愈。
LIVE_ACTIVITY="$ROOT/_sources/LiveActivity/ShallWeTalkLiveActivity.swift"
# 只查代码行:recordingRange 的文档注释里会提到 distantFuture(解释为什么不能用它)。
if grep "Date.distantFuture" "$LIVE_ACTIVITY" | grep -qv "//"; then
  fail "Live Activity timer range must be bounded; distantFuture renders as blank on device"
fi

# 2026-08-07:灵动岛**紧凑态与 minimal 只能用 SF Symbol**。build 109 把它们换成自绘的
# BrandWaveform 后,真机上一片空白 —— 紧凑区尺寸约束很紧,自绘视图容易被压成零尺寸,
# 而且失败是静默的(不崩、不报错、日志里卡片仍是 active,就是不画)。品牌标识只放展开态
# 与锁屏。改这两处前先在真机上确认,别再让"看不见"的回归混过去。
# 守卫范围从"紧凑态"扩大到**整个 DynamicIsland 闭包**:build 111 只退了紧凑态、展开态
# 仍留自绘视图,真机上灵动岛依然空白 —— 展开区渲染失败会把整张卡片一起拖垮。
if awk '/dynamicIsland: \{ context in/,/^        \}$/' "$LIVE_ACTIVITY" | grep -v "//" | grep -q "BrandWaveform("; then
  fail "No custom-drawn view anywhere inside DynamicIsland; it renders the whole card blank"
fi

grep -q "func ensureRecording" "$ROOT/_sources/App/CaptureLiveActivityController.swift" \
  && grep -q "CaptureLiveActivityController.shared.ensureRecording" "$DICTATION" \
  || fail "Action-button recording must keep (and rebuild) its Live Activity for the whole session"

# 2026-08-06:待命是**偏好**不是运行时状态 —— 装机即开,只有用户刻意关掉才关。
# 三条不变式:①偏好默认 true;②只有 setStandbyEnabled(用户拨开关)会写偏好,到期/中断/
# 回收走的 deactivateStandby 不得碰它;③偏好关掉后键盘口述不得再把它偷偷打开。
grep -q 'standbyPreferredOn") var standbyPreferredOn = true' "$ROOT/_sources/Shared/MobileSettingsStore.swift" \
  || fail "Standby must default to ON for fresh installs"

grep -A2 "func setStandbyEnabled" "$DICTATION" | grep -q "settings.standbyPreferredOn = enabled" \
  || fail "Only the user-facing toggle may write the standby preference"

grep -A2 "private func autoEnableKeyboardStandbyIfNeeded" "$DICTATION" | grep -q "guard settings.standbyPreferredOn" \
  || fail "Keyboard dictation must not silently re-enable standby the user turned off"

grep -q "func armStandbyIfPreferred" "$DICTATION" \
  && grep -q "controller.armStandbyIfPreferred()" "$ROOT/_sources/App/VoicePenMobileApp.swift" \
  || fail "Standby must be re-armed on foreground when the preference is on"

# 开关必须读偏好而不是运行时状态,否则用户会看到自己没碰过的开关自己弹回关闭。
grep -q "get: { standbyPreferredOn }" "$ROOT/_sources/App/Views.swift" \
  || fail "Standby toggle must reflect the persisted preference, not the live PiP state"

# 2026-08-06:发送/换行键必须按宿主声明的 returnKeyType 标注,不得写死"发送"。
# 键盘扩展**没有任何 API 能触发宿主的发送动作**(UITextDocumentProxy 只有 insertText /
# deleteBackward / adjustTextPosition),那个 "\n" 算发送还是换行完全由宿主解释:iMessage
# 当发送,WhatsApp / Telegram 只换行。做不到真发送,至少不能把"换行"画成"发送"。
grep -q "textDocumentProxy.returnKeyType" "$KEYBOARD" \
  || fail "Send key must follow the host's declared returnKeyType, not a hard-coded label"

grep -q "func refreshReturnKeyLabel" "$KEYBOARD" \
  && grep -q "refreshReturnKeyLabel()" "$KEYBOARD" \
  || fail "Return key label must be refreshed when the host or text field changes"

# 语音面只保留控制行，不能重新引入顶部文字卡片。
! grep -q "voiceTextCardHeight\|voiceTextCardTopInset" "$KEYBOARD" \
  || fail "Voice face must not reserve space for a removed text card"

# 第 1 排字母必须用 .fillEqually,不得回到"每键一条 999 优先级宽度约束"的写法——
# 那种写法下 Auto Layout 会挑其中一条断开,被挑中的键失去宽度、错位且点不中
# (2026-08-03 真机上表现为 e 键显示异常且无法点击)。
grep -q 'makeEqualKeyRow(\["q", "w", "e"' "$KEYBOARD" \
  || fail "Top letter row must use makeEqualKeyRow so no single key can lose its width constraint"

! grep -q "makeBottomSpacer" "$KEYBOARD" \
  || fail "Keyboard must not add a bottom spacer that creates unused space above the system bar"

# iOS 标准截图:字母键实心区域 135px@3x = 45pt；相邻行起点差 168px = 56pt，净间距 11pt。
grep -q "letterKeyHeight: CGFloat = 45" "$KEYBOARD" \
  || fail "Keyboard letter keys must use the measured 45pt system height"
grep -q "letterRowSpacing: CGFloat = 11" "$KEYBOARD" \
  || fail "Keyboard letter rows must use the measured 11pt system spacing"

# 2026-07-13:字母键改统一宽度 k(见 pinKeyWidth/makeTopLetterRow 等),不再用 fillEqually 撑宽 9/7 键行；
# 顶排 hGap 用 row.spacing = 6(= hGap 常量)表达,守卫同步为新几何间隙值。
grep -q "row.spacing = Self.hGap" "$KEYBOARD" \
  || fail "Keyboard letter rows should use the uniform hGap spacing (no more fillEqually stretch)"

# 2026-08-04 键帽视觉基准。全部来自对 iOS 26.5 系统键盘截图(iPhone Air / 420pt / 深色)的
# 逐像素取样,不是手感值:键区贴边 4pt、shift/删除 1.35k、圆角 5pt、字号 25pt、
# 键帽字形纯白/纯黑、投影黑 @40%(深)/@34%(浅)。改动前请先重测,不要凭观感调。
grep -q "keyFieldSideInset: CGFloat = 4" "$KEYBOARD" \
  || fail "Key field must sit 4pt from the screen edge (measured system value; 8pt shrinks each key by 0.8pt)"
grep -q "sideKeyWidthMultiplier: CGFloat = 0.135" "$KEYBOARD" \
  && grep -q "row3GapMultiplier: CGFloat = 0.015" "$KEYBOARD" \
  || fail "Shift/delete must be 1.35k wide with the matching 14.33pt side gap (measured system geometry)"
grep -q "keycapCornerRadius: CGFloat = 5" "$KEYBOARD" \
  && grep -q "keycapTitleSize: CGFloat = 25" "$KEYBOARD" \
  || fail "Keycaps must use the measured 5pt corner radius and 25pt letter size"
grep -q "config.baseForegroundColor = KeyboardTheme.keyLabel" "$KEYBOARD" \
  && ! grep -q "config.baseForegroundColor = KeyboardTheme.ink(alpha: 0.6)" "$KEYBOARD" \
  || fail "Keycap glyphs must use the full-contrast keyLabel token, not a dimmed ink alpha"
grep -q "button.layer.shadowColor = UIColor.black.cgColor" "$KEYBOARD" \
  && grep -q "dark ? 0.40 : 0.34" "$KEYBOARD" \
  || fail "Keycap drop shadow must be black at the measured 40%/34% opacities"
grep -q "button.layer.shadowPath = UIBezierPath(" "$KEYBOARD" \
  || fail "Keycap shadows must set an explicit rounded-rect shadowPath (shape + offscreen-render cost)"

# 2026-08-04 候选栏双模式。用户的两条硬规则:①候选词一旦出现,除非优先级变了,位置不得
# 相对移动;②候选词永远不许出现省略号。等宽槽只有 54.8pt,放不下 4 字以上的词,两条无法
# 同时满足,拍板为"这一批出现放不下的长词就整批退回变宽单行"。以下守卫锁住这个结构。
grep -Fq "candidateStack.distribution = fixedSlots ? .fillEqually : .fill" "$KEYBOARD" \
  && ! grep -q "candidateStack.spacing = 16" "$KEYBOARD" \
  || fail "Candidate bar must switch between fixed equal slots and the loose fallback in one place"
grep -Fq "candidateStack.widthAnchor.constraint(" "$KEYBOARD" \
  && grep -Fq "candidateStackWidthConstraint?.isActive = fixedSlots" "$KEYBOARD" \
  || fail "Fixed-slot mode needs a definite stack width; loose mode must release it to size to content"
# ★ 不省略这条规则的实现要害:判定用的字体必须就是渲染用的字体,槽宽必须来自真实 bounds。
# 一旦有人把它改成"按字数拍一个阈值",换字体/机型就会重新出现省略号。
grep -Fq "size(withAttributes: [.font: Self.candidateFont])" "$KEYBOARD" \
  && grep -Fq "candidateScroll.bounds.width" "$KEYBOARD" \
  || fail "Fixed-slot fit test must measure the real string width against the real slot width"
! grep -q "candidateFontSize(forCharacterCount" "$KEYBOARD" \
  || fail "Candidates must not be shrunk by character count — that was the change that still truncated"

# 2026-08-04 按下反馈 + 去防抖。真机诊断日志几分钟打字里 [KB][perf] 一条都没有,
# 说明候选计算/渲染从未超过一帧——那 24ms 防抖是在防一个不存在的问题,只留下延迟本身。
! grep -q "candidateRenderDebounce" "$KEYBOARD" \
  || fail "Candidate render debounce must stay removed — measured compute/render never exceeded one frame"
grep -Fq "for: [.touchDown, .touchDragEnter]" "$KEYBOARD" \
  || fail "Key press feedback must fire on touch-down; waiting for touch-up is what felt slow"
grep -q "KeycapPreviewView" "$KEYBOARD" \
  && test -f "$ROOT/_sources/Keyboard/KeycapPreview.swift" \
  || fail "Letter keys need the pop-up keycap preview for press feedback"
# 用户明确要求:反馈只能是视觉的,不要按键音。
! grep -qE "playInputClick|AudioServicesPlaySystemSound" "$KEYBOARD" "$ROOT/_sources/Keyboard/KeycapPreview.swift" \
  || fail "Key feedback must stay visual only — the user explicitly ruled out click sounds"

# 2026-08-04 漏点:键与键之间的缝上的触摸必须改判给最近的键,否则那一下什么都没输入,
# 而拼音少一个字母整串就可能拼不出音节。
grep -q "KeyFieldStackView()" "$KEYBOARD" \
  && test -f "$ROOT/_sources/Keyboard/KeyFieldStackView.swift" \
  || fail "Letter/symbol pages must use KeyFieldStackView so taps in the gaps snap to the nearest key"

# 2026-08-04 错点纠正 + "候选栏永不为空"。这些是运行时行为,grep 锁不住,真跑一遍引擎。
PINYIN_SMOKE_DIR="${TMPDIR:-/tmp}/voicepen-pinyin-smoke"
rm -rf "$PINYIN_SMOKE_DIR" && mkdir -p "$PINYIN_SMOKE_DIR"
python3 "$ROOT/tests/pinyin_index_resources.py" || fail "Indexed resources are inconsistent"
# PinyinDictionary 走 Bundle.main 找资源;命令行工具的 Bundle.main 就是可执行文件所在目录。
cp "$ROOT/_sources/Keyboard/PinyinData/"*.txt "$PINYIN_SMOKE_DIR/" \
  || fail "Pinyin smoke test could not stage the dictionary resources"
cp "$ROOT/_sources/Keyboard/PinyinData/"*.sqlite "$PINYIN_SMOKE_DIR/" \
  || fail "Indexed dictionary resource missing"
xcrun swiftc -O -parse-as-library \
  "$ROOT/_sources/Keyboard/Pinyin/PinyinEngine.swift" \
  "$ROOT/_sources/Keyboard/Pinyin/PinyinDictionary.swift" \
  "$ROOT/_sources/Keyboard/Pinyin/PinyinIndexedStore.swift" \
  "$ROOT/_sources/Keyboard/Pinyin/PinyinSegmenter.swift" \
  "$ROOT/_sources/Keyboard/Pinyin/PinyinCorrector.swift" \
  "$ROOT/_sources/Keyboard/Pinyin/T9KeyMap.swift" \
  "$ROOT/_sources/Keyboard/Pinyin/T9Index.swift" \
  "$ROOT/tests/PinyinCorrectionSmoke.swift" \
  -o "$PINYIN_SMOKE_DIR/smoke" \
  || fail "Pinyin correction smoke test failed to compile"
"$PINYIN_SMOKE_DIR/smoke" \
  || fail "Pinyin correction smoke test failed (see FAIL line above)"
xcrun swiftc -O -parse-as-library \
  "$ROOT/_sources/Keyboard/Pinyin/"*.swift \
  "$ROOT/tests/PinyinSelectionSmoke.swift" \
  -o "$PINYIN_SMOKE_DIR/selection" \
  || fail "Pinyin selection test failed to compile"
"$PINYIN_SMOKE_DIR/selection" \
  || fail "Pinyin selection must preserve unconsumed input"
xcrun swiftc -O -parse-as-library \
  "$ROOT/_sources/Keyboard/Pinyin/"*.swift \
  "$ROOT/tests/PinyinIndexedStoreSmoke.swift" -o "$PINYIN_SMOKE_DIR/indexed" \
  || fail "Indexed dictionary test failed to compile"
"$PINYIN_SMOKE_DIR/indexed" || fail "Indexed dictionary acceptance failed"
rm -rf "$PINYIN_SMOKE_DIR"

PREFERENCE_SMOKE_DIR="${TMPDIR:-/tmp}/voicepen-keyboard-preference-smoke"
rm -rf "$PREFERENCE_SMOKE_DIR" && mkdir -p "$PREFERENCE_SMOKE_DIR"
xcrun swiftc -O -parse-as-library \
  "$ROOT/_sources/Shared/AppGroup.swift" \
  "$ROOT/_sources/Keyboard/SharedKeyboardPreferenceStore.swift" \
  "$ROOT/tests/KeyboardPreferenceSmoke.swift" \
  -o "$PREFERENCE_SMOKE_DIR/smoke" \
  || fail "Keyboard preference smoke test failed to compile"
"$PREFERENCE_SMOKE_DIR/smoke" \
  || fail "Keyboard preference smoke test failed"
rm -rf "$PREFERENCE_SMOKE_DIR"

! grep -q "panel.addArrangedSubview(liveLabel)" "$KEYBOARD" \
  || fail "Keyboard must not render a second status row below the voice button"

! grep -q "panel.addArrangedSubview(cacheLabel)" "$KEYBOARD" \
  || fail "Keyboard must not render a second cache row below the voice button"

grep -q "markInserted" "$KEYBOARD" \
  || fail "Keyboard must publish inserted text after automatic insertion"

grep -q "drainPendingText(expectedRequestID: snapshot.resultRequestID)" "$KEYBOARD" \
  || fail "A bridge poll must use one snapshot for both status rendering and pending-text delivery"

grep -q "currentBridgePhase = .inserted" "$KEYBOARD" \
  && grep -q "currentProcessingStage = nil" "$KEYBOARD" \
  && grep -q "processingBeganAt = nil" "$KEYBOARD" \
  && grep -q "updateVoiceHeader(phase: .inserted)" "$KEYBOARD" \
  || fail "Successful text insertion must synchronously leave the local processing UI"

grep -q "beginBackgroundTask" "$DICTATION" \
  || fail "Dictation controller must keep a finite keyboard background window"

grep -q "isStarting" "$DICTATION" \
  || fail "Dictation controller must guard against concurrent recorder starts"

grep -q "case .stop" "$DICTATION" \
  || fail "Dictation controller must handle keyboard stop requests"

grep -q "static let freeAccountBuild = false" "$APP_GROUP" \
  || fail "Paid team build must use the real App Group bridge instead of the Darwin/pasteboard fallback"

grep -q "if phase == .recording || phase == .processing" "$DICTATION" \
  || fail "Darwin recording/processing events must repeat so a keyboard that reappears after launch catches the current state"

grep -q "if phase == .ready" "$DICTATION" \
  || fail "Darwin result events must repeat while a keyboard may be waiting to drain recognized text"

grep -q "removeTap(onBus: 0)" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Recorder must clear any existing input tap before installing a new one"

grep -q "let tapFormat: AVAudioFormat? = nil" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "iOS recorder tap must let the Audio Unit negotiate its native input format"

grep -q "engine = AVAudioEngine()" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Cold recording must rebuild AVAudioEngine after the audio route is active"

grep -q "setCategory(.playAndRecord" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Default iOS capture must use the Voice I/O-compatible audio-session category"

grep -q "mode: .voiceChat" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Default iOS capture must request the system voice-optimized session mode"

grep -q "setVoiceProcessingEnabled(true)" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Recorder must enable iOS system voice processing"

grep -q "isVoiceProcessingAGCEnabled = true" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Recorder must explicitly enable iOS automatic gain control"

grep -q "startIOSCapture(useSystemVoiceProcessing: false)" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Recorder must fall back when Voice I/O is unavailable on the current route"

grep -q "setCategory(.record" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Recorder must preserve the previously validated measurement-mode compatibility fallback"

grep -q "input.inputFormat(forBus: 0)" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Recorder must validate the input node's hardware format"

grep -q "e.code == -10868" "$DICTATION" \
  || fail "Cold recording must retry transient Audio Unit format negotiation failures"

grep -q "engine.reset()" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Recorder must reset AVAudioEngine before the next recording"

grep -q "let shouldCapture = capturing" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Recorder audio-thread capture gate must read state under the recorder lock"

grep -q "capturing = true" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Recorder must open the sampling gate before starting the audio engine"

grep -q "取样结束 pcm=" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Recorder must log captured PCM bytes so silent/empty recordings are diagnosable"

grep -q "guard wav.count >= 1_644" "$DICTATION" \
  || fail "Dictation must reject an empty microphone capture before sending it to ASR"

empty_guard_line="$(grep -n 'guard wav.count >= 1_644' "$DICTATION" | head -1 | cut -d: -f1)"
[ -n "$archive_line" ] && [ -n "$empty_guard_line" ] && [ "$archive_line" -lt "$empty_guard_line" ] \
  || fail "Every stopped recording must begin audio archival before the empty-sample guard"

grep -q "let shouldCreateTodo = mode == .todoCapture || hitsTrigger" "$DICTATION" \
  || fail "Todo trigger words must still create todos from keyboard dictation"

grep -q "let shouldDeliverText = mode == .keyboard || mode == .capture || !shouldCreateTodo" "$DICTATION" \
  || fail "Keyboard dictation must always return text to the active input field, including when it also creates a todo"

grep -q "DictationPolicy.cleanupPromptRoute" "$DICTATION" \
  || fail "Initial cleanup must route short/full prompts by shared recording-duration policy"
# 2026-08-05:默认阈值由 20 秒下调为 10 秒。依据是 1215 条历史里 91% 的口述落在短路由,
# 而短路由 prompt 明令"不分段、不编号",用户的分段编号意愿因此几乎全部落空。
# 这一行是刻意的契约变更,不是为了让脚本通过——再调阈值请连同 §12.17 的记录一起更新。
grep -q "defaultFullCleanupThresholdSeconds: TimeInterval = 10" "$DICTATION_POLICY" \
  || fail "Full cleanup must default to a 10-second recording threshold"
# 2026-08-16:短路由不再是独立的同音纠错专用 prompt。2026-08-29 再增加成组列举
# 路由，三条路线统一由共享 builder 组装，调用端不得自行拼接而发生漂移。
grep -q "PromptBuilder.buildDictation" "$DICTATION" \
  || fail "Dictation must use the shared short/full/enumeration prompt builder"
grep -q "transcript: raw" "$DICTATION" \
  || fail "Cleanup routing must inspect the finalized ASR transcript"
grep -q "explicitEnumerationSignalPairs" "$DICTATION_POLICY" \
  || fail "Cleanup policy must recognize paired enumeration signals"

# 2026-08-06:**刻意的契约变更,不是为了让脚本通过**,详见 §12.21/§12.22。
# 历史上这里有过两版相反的守卫,都已作废:
#   ① 原 `cleanupRoute == .full`——"短口述待办不得再发第二次 LLM 提取请求"(§12.15
#      延迟基线的取舍)。代价是短待办只做同音纠错,"提醒我"原样留在条目里、多件事不拆行。
#   ② 当日中途的 `usesTodoCleanup`——按去向选**唯一**一份 prompt。代价是记录跟着变成
#      待办条目格式,用户当天即反馈"记录里也被删成了待办"。
# 现行契约:记录与待办是两个独立产出,各跑各的 prompt,谁也不改写谁。
#   - 记录 `clean`:严格按录音时长走 homophoneOnly / 分段 / 完整文章整理,capture 不例外。
#   - 待办 `items`:无条件再跑一次 extractTodos(待办 prompt),不看时长、不看入口。
# 代价是进待办的口述必然两次 LLM 请求。这是刻意接受的:一份要保完整语义,一份要条目化。
grep -q "IntentRouter.extractTodos(" "$DICTATION" \
  || fail "Todo items must always go through the dedicated todo prompt"

grep -qE "let items = await IntentRouter.extractTodos\(" "$DICTATION" \
  || fail "Todo extraction must be unconditional — no duration threshold, no per-entry special case"

# 反向守卫:记录的整理稿不得被直接当成待办条目复用(那样等于两者共用一份 prompt)。
# 注意 `todoFormattingPrompt` / `parseTodoLines(refined)` 在 refineTodo(待办「重新识别」)
# 里是合法的,所以这里只钉死 `(clean)` 这个参数。
if grep -q "IntentRouter.parseTodoLines(clean)" "$DICTATION"; then
  fail "Record cleanup must not be reused as todo items; run the todo prompt instead"
fi

# 记录整理必须由共享路由选择短/长/显式列举 prompt，capture 不得按去向覆盖该裁决。
grep -q "route: cleanupRoute" "$DICTATION" \
  || fail "The record's cleanup chain must use the shared cleanup route"

# 整理请求失败时，历史记录必须保存未经整理的 ASR 原文；失败回退不能再经过人工纠错改写。
grep -q "private enum CleanupAttempt" "$DICTATION" \
  && grep -q "cleanupFellBackToRaw = true" "$DICTATION" \
  && grep -q "if !cleanupFellBackToRaw" "$DICTATION" \
  && grep -q "history.append(record)" "$DICTATION" \
  || fail "Cleanup failure must preserve the original ASR text in history"

grep -q "IntentRouter.shouldCreateTodo(rawText: raw, cleanedText: clean)" "$DICTATION" \
  && grep -q "looksLikeTodo(rawText) || looksLikeTodo(cleanedText)" "$ROOT/_sources/Shared/IntentRouter.swift" \
  || fail "Todo routing must fire whether the trigger word survives cleanup or only exists in the raw text"

grep -q "if mode == .capture" "$DICTATION" \
  || fail "Action capture must still drive its own Live Activity stages"

# 2026-08-07:勾选完成必须删掉对应日历事项,取消完成必须建回来。
# 成对是硬要求 —— 只删不还的话,误点一次「完成」再取消,日程就悄悄没了,而用户不会想到
# 要去日历里补;这类静默的数据丢失比没有这个功能更糟。
TODO_STORE_SRC="$ROOT/_sources/Shared/TodoStore.swift"
grep -A20 "func toggle(_ id: UUID)" "$TODO_STORE_SRC" | grep -q "TodoCalendarScheduler.shared.remove" \
  || fail "Completing a todo must remove its calendar event"

grep -A20 "func toggle(_ id: UUID)" "$TODO_STORE_SRC" | grep -q "restoreCalendarEvent" \
  || fail "Un-completing a todo must restore the calendar event it deleted"

# 重建锚点必须是 createdAt。用"现在"解析「8月7号」这种不带年份的日期,已过去的会被推到
# 明年,建出错年份的日程(TodoDateResolverSmoke 里有正反两个用例锁住)。
grep -A6 "private func restoreCalendarEvent" "$TODO_STORE_SRC" | grep -q "spokenAt: item.createdAt" \
  || fail "Calendar restore must re-resolve against the todo's createdAt, never the current time"

grep -q "replaceRecordingGroup" "$DICTATION" \
  || fail "Todo refine must replace every sibling created from the same recording"

grep -q "TodoDateResolver.resolve" "$DICTATION" \
  || fail "Todo creation and refine must resolve spoken relative dates deterministically"

grep -q "value: -3" "$ROOT/_sources/Shared/TodoStore.swift" \
  || fail "Relative todo dates must use the 3 AM semantic-day cutoff"

grep -q "TodoCalendarScheduler.shared.upsert" "$DICTATION" \
  || fail "Dated todos must be enqueued into iOS Calendar"

grep -q "NSCalendarsFullAccessUsageDescription" "$APP_INFO" \
  || fail "Calendar auto-creation must declare the iOS full-access usage description"

DATE_SMOKE_BIN="${TMPDIR:-/tmp}/voicepen-todo-date-smoke"
xcrun swiftc -parse-as-library \
  "$ROOT/_sources/Shared/TodoStore.swift" \
  "$ROOT/_sources/Shared/AppDataDirectory.swift" \
  "$ROOT/_sources/Shared/DiagLog.swift" \
  "$ROOT/_sources/Shared/AppGroup.swift" \
  "$ROOT/tests/TodoDateResolverSmoke.swift" \
  -o "$DATE_SMOKE_BIN" \
  || fail "Todo date resolver smoke test failed to compile"
"$DATE_SMOKE_BIN" \
  || fail "Todo date resolver returned an incorrect concrete date"
rm -f "$DATE_SMOKE_BIN"

# 待办契约 2026-08-03 从 iOS 内联文本下沉到 core,与 macOS 共用同一份
# (此前两端各一份,同一句口述会拆出不同条目)。断言改指契约的新位置。
TODO_PROMPT="$ROOT/../core/Sources/ShallWeTalkCore/TodoPrompt.swift"
grep -q "说了几件事就输出几行" "$TODO_PROMPT" \
  || fail "Todo prompt must require exactly one output line per spoken task"
grep -q "TodoPrompt.formattingPrompt" "$ROOT/_sources/Shared/IntentRouter.swift" \
  || fail "iOS IntentRouter must use the shared core todo contract, not an inlined copy"
grep -q "TodoPrompt.formattingPrompt" "$ROOT/../macos/VoicePen/Services/IntentRouter.swift" \
  || fail "macOS IntentRouter must use the shared core todo contract, not an inlined copy"

# 个人词典必须进待办 prompt 的全部四条路径,否则同一个专名在待办里和正文里写法会不一致。
grep -q "dictionary: settings.dictionaryWords" "$DICTATION" \
  || fail "iOS todo extraction must inject the personal dictionary"
grep -A2 "IntentRouter.extractTodos(" "$DICTATION" | grep -q "dictionary: settings.dictionaryWords" \
  || fail "iOS extractTodos call site must pass the personal dictionary"
grep -A2 "IntentRouter.extractTodos(" "$ROOT/../macos/VoicePen/AppState.swift" \
  | grep -q "dictionary: settings.dictionaryWords" \
  || fail "macOS extractTodos call site must pass the personal dictionary"

grep -q "static var openAppWhenRun: Bool { false }" "$ROOT/_sources/App/ActionCaptureIntent.swift" \
  || fail "Action Button intent must run without opening the full app UI"

grep -q "foreground(.dynamic)" "$ROOT/_sources/App/ActionCaptureIntent.swift" \
  || fail "Cold Action Button recording must be allowed to continue in the foreground on iOS 26"

grep -q "AudioRecordingIntent" "$ROOT/_sources/App/ActionCaptureIntent.swift" \
  || fail "Action Button background recording must adopt AudioRecordingIntent"

# 产品说明必须准确保留 Action Button 的强制退出边界。不能简化成“App 必须一直在后台”，
# 否则会误导用户开启 PiP；真正前提是没有从多任务界面上划强退，强退后先手动打开一次。
grep -q "若从多任务界面上划关闭 App" "$ROOT/_sources/App/Views.swift" \
  || fail "Action Button product copy must explain the force-quit relaunch requirement"
grep -q "无需保持 App 前台，也不要求开启画中画待命" "$ROOT/_sources/App/Views.swift" \
  || fail "Action Button product copy must distinguish background eligibility from PiP standby"
grep -q "操作按钮的后台可唤醒前提" "$ROOT/README.md" \
  || fail "iOS README must preserve the Action Button force-quit product boundary"

grep -q "ActionCaptureSessionStore.isRecording" "$ROOT/_sources/App/ActionCaptureIntent.swift" \
  || fail "A second Action Button press must use cross-process recording state"

grep -q "DarwinBridge.cmdCaptureStop" "$ROOT/_sources/App/ActionCaptureIntent.swift" \
  || fail "A second Action Button press must signal the active recorder directly"

grep -q "DictationPolicy.withTimeout" "$DICTATION" \
  || fail "Action capture initial cleanup must have a hard latency ceiling"

grep -q "finishTimeoutSeconds" "$CORE/VolcStreamingSession.swift" \
  && grep -q "enabled ? 8 : 3" "$CORE/VolcStreamingSession.swift" \
  || fail "Streaming ASR finalization must bound pure streaming at 3 seconds and second-pass at 8 seconds"
grep -q "timeoutBudget(forPcmBytes: pcm.count)" "$CORE/VolcEngineASR.swift" \
  || fail "Batch ASR fallback must bound its end-to-end wait by a duration-scaled budget"
grep -q "task.cancel(with: .goingAway" "$CORE/VolcEngineASR.swift" \
  || fail "Batch ASR timeout must actively disconnect the WebSocket"

grep -q "mode == .capture" "$DICTATION" \
  || fail "Action capture must retain its dedicated processing route"

grep -q "NSSupportsLiveActivities" "$APP_INFO" \
  || fail "The app must declare Live Activity support for Action Button recording"

test -f "$ROOT/_sources/LiveActivity/ShallWeTalkLiveActivity.swift" \
  || fail "Dynamic Island Live Activity widget is missing"

grep -q "func meaningfulCharacterCount" "$DICTATION_POLICY" \
  || fail "The 20-character boundary must ignore whitespace and punctuation deterministically"

DICTATION_POLICY_SMOKE_BIN="${TMPDIR:-/tmp}/voicepen-dictation-policy-smoke"
xcrun swiftc -parse-as-library \
  "$DICTATION_POLICY" \
  "$CORE/CleanupService.swift" \
  "$CORE/PromptBuilder.swift" \
  "$ROOT/tests/DictationPolicySmoke.swift" \
  -o "$DICTATION_POLICY_SMOKE_BIN" \
  || fail "Short-dictation policy smoke test failed to compile"
"$DICTATION_POLICY_SMOKE_BIN" \
  || fail "Short-dictation policy returned the wrong <20 boundary"
rm -f "$DICTATION_POLICY_SMOKE_BIN"

# 输入框语义路由:搜索框强制短路由并由程序删除交付标点，IM 发送框按录音时长路由，
# 邮箱与数字框完全跳过整理。
HOST_FIELD_SMOKE_BIN="${TMPDIR:-/tmp}/voicepen-host-field-routing-smoke"
xcrun swiftc -parse-as-library \
  "$ROOT/_sources/Shared/HostFieldKind.swift" \
  "$ROOT/tests/HostFieldRoutingSmoke.swift" \
  -o "$HOST_FIELD_SMOKE_BIN" \
  || fail "Host-field routing smoke test failed to compile"
"$HOST_FIELD_SMOKE_BIN" \
  || fail "Host-field routing produced the wrong cleanup policy"
rm -f "$HOST_FIELD_SMOKE_BIN"

grep -q "activeFieldKind.textForDelivery(clean)" "$DICTATION" \
  || fail "Search-field delivery must apply the deterministic punctuation-removal policy"
grep -q "PendingTextStore.push(deliveryText" "$DICTATION" \
  || fail "Keyboard delivery must publish the field-normalized text"

# 键盘必须真的读 UITextInputTraits,而不是恒传 .general——否则整条路由是死的。
grep -q "textDocumentProxy.keyboardType" "$KEYBOARD" \
  || fail "The keyboard must derive host field semantics from keyboardType"
grep -q "requestRecording(fieldKind:" "$KEYBOARD" \
  || fail "Keyboard recording requests must carry the host field kind"
# 插入前必须过一次边界感知,否则英文后接口述会粘成一个词。
grep -q "boundaryAdjusted" "$KEYBOARD" \
  || fail "Inserted text must pass through insertion-boundary adjustment"
grep -q "documentContextAfterInput" "$KEYBOARD" \
  || fail "Insertion boundary needs the trailing context to de-duplicate punctuation"

grep -q "enum ThinkingMode" "$CORE/CleanupService.swift" \
  || fail "Cleanup requests must expose an explicit thinking-mode switch"

grep -q 'payload\["thinking"\] = \["type": thinking.rawValue\]' "$CORE/CleanupService.swift" \
  || fail "DeepSeek/Ark requests must send the native thinking.type API field"

grep -q "systemPrompt: prompt, thinking: .enabled" "$DICTATION" \
  || fail "Todo reorganization must explicitly enable model thinking"

grep -q '普通叙述不自动编号.*共同谓语下的并列词组' "$CORE/PromptBuilder.swift" \
  || fail "Initial cleanup prompt must preserve ordinary narration instead of forcing numbered lists"

# native nostream 长口述只允许一次整理；prompt 必须在同一次调用里完成校对、分段和编号。
grep -q 'public static let simpleBase' "$CORE/PromptBuilder.swift" \
  || fail "Cleanup prompt must expose the simplified rewrite instruction"
grep -q '三项明确任务.*按不同意思分段' "$CORE/PromptBuilder.swift" \
  || fail "Single-pass long cleanup must include segmentation and numbering"

grep -q 'bigmodel_nostream' "$ROOT/_sources/Shared/MobileSettingsStore.swift" \
  || fail "iOS must persist the native bigmodel_nostream endpoint"

! grep -q 'volcNostreamWsURL' "$DICTATION" \
  || fail "iOS main dictation must use the persisted native endpoint without URL rewriting"

! grep -q 'enable_nonstream' "$CORE/VolcEngineASR.swift" "$CORE/VolcStreamingSession.swift" \
  || fail "Native nostream requests must not send the async-only enable_nonstream option"

grep -q 'selected.count < 5_000' "$ROOT/_sources/Shared/MobileSettingsStore.swift" \
  || fail "ASR hotword context must support the provider's expanded capacity"

# PromptBuilder / DictionaryMiner 保真契约已迁入 core 包的 XCTest(见
# core/Tests/ShallWeTalkCoreTests/{PromptBuilderPreservationTests,DictionaryMinerTests}.swift)。
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path "$CORE_DIR" --scratch-path "$CORE_SCRATCH" \
    --filter PromptBuilderPreservationTests \
  || fail "Cleanup prompt changed protected wording or missed the homophone contract"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path "$CORE_DIR" --scratch-path "$CORE_SCRATCH" \
    --filter DictionaryMinerTests \
  || fail "Contextual correction learning generalized a user edit too broadly"

grep -q '三项明确任务.*按不同意思分段' "$CORE/PromptBuilder.swift" \
  || fail "Long dictation must merge segmentation and numbering into its single cleanup prompt"

! grep -q 'SegmentedCleaner\|runStructurePass\|buildStructurePass' "$DICTATION" \
  || fail "Native nostream iOS dictation must not run segmented or second-pass cleanup"

# 前缀匹配而非整行字面量:守的是“SSE 结果必须过一遍 validatedOutput”,
# 不是它的参数个数(2026-08-14 加 forbidsNewNumbers 时被整行匹配误伤过一次)。
grep -q 'validatedOutput(acc, original: raw' "$CORE/CleanupService.swift" \
  || fail "Cleanup must reject model meta explanations"

# VAD 降级路径:模型加载失败时必须仍有 RMS 判定推进 lastVoiceAt,
# 否则静音一路累积到自动停录,等于每次录音都作废。
grep -q 'if !voiceActivity.isAvailable, raw > 0.18' "$DICTATION" \
  || fail "VAD must fall back to the RMS threshold when the model is unavailable"
grep -q 'voiceActivity.feed(chunk)' "$DICTATION" \
  || fail "the VAD must be fed PCM from the recorder"
grep -q 'voiceActivity.reset()' "$DICTATION" \
  || fail "VAD state must be reset before each recording"

# 反向数字守卫:短同音纠错路由必须开着,否则模型凭空补出的金额/区间端点会直接进用户文本。
grep -q 'forbidsNewNumbers: cleanupRoute == .homophoneOnly' "$DICTATION" \
  || fail "Short homophone route must reject hallucinated numbers"
grep -q 'customInstruction: activeCleanup.customInstruction' "$MAC_APP_STATE" \
  || fail "macOS short and long dictation must both carry the resolved custom prompt"
grep -q 'PromptBuilder.buildDictation' "$MAC_APP_STATE" \
  || fail "macOS dictation must use the same short/full/enumeration prompt switch as iOS"
grep -q 'forbidsNewNumbers: cleanupRoute == .homophoneOnly' "$MAC_APP_STATE" \
  || fail "macOS short dictation must use the same new-number guard as iOS"
grep -q 'introducedNumericToken' "$CORE/CleanupService.swift" \
  || fail "validatedOutput must guard against numbers the model invented"

grep -q "private var ownsActiveSession = false" "$ROOT/_sources/App/AudioPlayback.swift" \
  || fail "Audio playback must track whether it owns the active audio session"

grep -q "if hadPlaybackSession { deactivate() }" "$ROOT/_sources/App/AudioPlayback.swift" \
  || fail "A no-op playback stop must not deactivate the recorder's microphone session"

grep -q "func prepareForAudioPlayback()" "$DICTATION" \
  || fail "Playback must be able to tear down a retained warm recorder session"

grep -q '回放前拆除 Recorder 暖会话' "$DICTATION" \
  || fail "Playback takeover of the shared audio session must be diagnosable"

grep -q "QuietInkPlaybackPill(" "$ROOT/_sources/App/TodoCard.swift" \
  || fail "Todo audio must reuse the shared Quiet Ink playback pill"
grep -q "case available(duration: String)" "$QUIET_INK_COMPONENTS" \
  || fail "Idle todo playback pill must show audio duration instead of a text label"
! grep -q 'available(label: "播放原音")' "$ROOT/_sources/App/TodoCard.swift" \
  || fail "Todo playback pill must not display 播放原音 beside the play icon"
grep -q 'Text("\\(elapsed) / \\(total)")' "$QUIET_INK_COMPONENTS" \
  || fail "Playing todo audio must show elapsed and total time"
grep -q 'frame(width: 64, height: 2.5)' "$QUIET_INK_COMPONENTS" \
  || fail "Playing todo audio must expose the Turn 4 progress track"
grep -q 'asset.load(.duration)' "$ROOT/_sources/App/TodoCard.swift" \
  || fail "Todo cards must read the actual archived-audio duration"

! grep -q "struct AudioPill" "$ROOT/_sources/App/TodoCard.swift" \
  || fail "Todo must not keep a divergent audio playback control"

! grep -q "if settings.keepAudio" "$DICTATION" \
  || fail "Every recognized recording must archive its original audio"

! grep -q "exportAsynchronously" "$ROOT/_sources/Shared/HistoryStore.swift" \
  || fail "Audio archival must not depend on a potentially stuck AVAssetExportSession"

grep -q "audioArchive.*归档成功" "$ROOT/_sources/Shared/HistoryStore.swift" \
  || fail "Audio archive success must be visible in device diagnostics"

grep -q "sourceRecordID" "$ROOT/_sources/Shared/TodoStore.swift" \
  || fail "Todo items must retain their source recording for playback"

grep -q 'accessibilityLabel(isRefining ? "正在重新识别" : "重新识别")' "$QUIET_INK_COMPONENTS" \
  || fail "Shared refine button must expose precision re-recognition"

grep -q "TodoReorderDropDelegate" "$ROOT/_sources/App/Views.swift" \
  || fail "Todo rows must support long-press drag reordering"

grep -q "setActive(false" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Recorder must deactivate the iOS audio session after stopping"

grep -q "resolveInputFormat" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Recorder must wait for iOS to publish a valid input route before failing"

grep -q "audioRouteDiagnostics" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Recorder errors must include audio route diagnostics for no-input failures"

grep -q "availableInputs" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Recorder must inspect AVAudioSession available inputs when starting"

grep -q "KeyboardBridgeStore.swift in Sources" "$PROJECT" \
  || fail "Xcode project must compile KeyboardBridgeStore into app and keyboard targets"

grep -A1 "<key>IsASCIICapable</key>" "$KEYBOARD_INFO" | grep -q "<true/>" \
  || fail "Keyboard must declare IsASCIICapable=true for ordinary text fields"

test -f "$APP_ENTITLEMENTS" \
  || fail "App entitlements are missing"

test -f "$KEYBOARD_ENTITLEMENTS" \
  || fail "Keyboard entitlements are missing"

grep -q "group.org.example.voicepen" "$APP_ENTITLEMENTS" \
  || fail "App must declare the shared App Group used by PendingTextStore"

test -f "$APP_ICLOUD_ENTITLEMENTS" \
  || fail "App iCloud entitlement template is missing"

grep -q "com.apple.developer.icloud-container-identifiers" "$APP_ICLOUD_ENTITLEMENTS" \
  || fail "App iCloud template must declare the iCloud container identifiers entitlement"

grep -q "iCloud.org.example.voicepen" "$APP_ICLOUD_ENTITLEMENTS" \
  || fail "App iCloud template must declare the Shall We Talk iCloud container"

grep -q "com.apple.developer.icloud-services" "$APP_ICLOUD_ENTITLEMENTS" \
  || fail "App iCloud template must declare iCloud services"

grep -q "CloudDocuments" "$APP_ICLOUD_ENTITLEMENTS" \
  || fail "App iCloud template must enable iCloud Documents"

grep -q "lastCloudSyncStatus" "$DICTATION" \
  || fail "Dictation controller must publish a visible iCloud sync status"

grep -q "syncHistoryToCloud" "$DICTATION" \
  || fail "Dictation controller must support manual iCloud push"

grep -q "Task.detached(priority: .utility)" "$DICTATION" \
  || fail "iCloud file reads/writes must run off MainActor so recording controls remain responsive"

grep -q "group.org.example.voicepen" "$KEYBOARD_ENTITLEMENTS" \
  || fail "Keyboard must declare the same shared App Group used by PendingTextStore"

# 付费团队模式:主路径必须稳定走 App Group 实时桥。
grep -q "static let freeAccountBuild = false" "$ROOT/_sources/Shared/AppGroup.swift" \
  || fail "Paid team mode must enable real App Group sharing"

# 2026-07-11 起改用 App.iCloud.entitlements(含 App Group + iCloud 容器)启用历史同步
grep -q "CODE_SIGN_ENTITLEMENTS: _sources/App/App.iCloud.entitlements" "$ROOT/project.yml" \
  || fail "project.yml must sign the app with App.iCloud.entitlements (App Group + iCloud container) for history sync"

grep -q "CODE_SIGN_ENTITLEMENTS: _sources/Keyboard/Keyboard.entitlements" "$ROOT/project.yml" \
  || fail "project.yml must sign the keyboard with App Group entitlements in paid mode"

grep -q "CODE_SIGN_ENTITLEMENTS = _sources/App/App.iCloud.entitlements" "$PROJECT" \
  || fail "Xcode project must sign the app with App.iCloud.entitlements (re-run xcodegen)"

grep -q "CODE_SIGN_ENTITLEMENTS = _sources/Keyboard/Keyboard.entitlements" "$PROJECT" \
  || fail "Xcode project must sign the keyboard with Keyboard.entitlements (re-run xcodegen)"

test -f "$APP_ICON/Contents.json" \
  || fail "AppIcon asset catalog is missing"

test -f "$APP_ICON/icon-1024.png" \
  || fail "AppIcon 1024px source image is missing"

grep -q "Assets.xcassets" "$PROJECT" \
  || fail "Xcode project must include Assets.xcassets"

# ---------- 中文全拼输入法(纯 Swift 引擎 + 同源词库) ----------
PINYIN_DIR="$ROOT/_sources/Keyboard/PinyinData"
ENGINE_DIR="$ROOT/_sources/Keyboard/Pinyin"
SHARED_DICT="$ROOT/_sources/Shared/SharedDictionaryStore.swift"

test -f "$PINYIN_DIR/pinyin_dict.txt" \
  || fail "Pinyin dictionary resource is missing (run tools/build_pinyin_dict.py)"

test -f "$PINYIN_DIR/pinyin_syllables.txt" \
  || fail "Pinyin syllable inventory resource is missing"

test -f "$PINYIN_DIR/char_pinyin.txt" \
  || fail "Char->pinyin map resource is missing (needed for hotword sync)"

# 音节表应接近普通话音节数(~408),防止空文件/截断
test "$(grep -c . "$PINYIN_DIR/pinyin_syllables.txt")" -ge 400 \
  || fail "Pinyin syllable inventory looks truncated (<400 syllables)"

# 词库应为 词<TAB>音节<TAB>频率 三列,且含常用词
grep -qP "^你好\t" "$PINYIN_DIR/pinyin_dict.txt" 2>/dev/null \
  || grep -q "^你好	" "$PINYIN_DIR/pinyin_dict.txt" \
  || fail "Pinyin dictionary missing expected entry/format (word<TAB>syllables<TAB>freq)"

# 开源词库合并后的代表性通用/科技/医疗词必须进入运行时前 50,000 条。
for expected_word in 人工智能 输入法 云计算 二维码 核酸 机器学习 深度学习 支付宝 公众号 朋友圈 小红书 短视频 待办 微信群 直播间 新能源; do
  awk -F '\t' -v word="$expected_word" 'NR <= 50000 && $1 == word { found=1; exit } END { exit !found }' "$PINYIN_DIR/pinyin_dict.txt" \
    || fail "Expanded open-source dictionary missing runtime-core word: $expected_word"
done

test -f "$ROOT/THIRD_PARTY_LEXICONS.md" \
  || fail "Third-party lexicon attribution is missing"

test -f "$ENGINE_DIR/PinyinEngine.swift" \
  || fail "PinyinEngine.swift is missing"

test -f "$ENGINE_DIR/PinyinDictionary.swift" \
  || fail "PinyinDictionary.swift is missing"

test -f "$ENGINE_DIR/PinyinSegmenter.swift" \
  || fail "PinyinSegmenter.swift is missing"

test -f "$ENGINE_DIR/T9KeyMap.swift" \
  || fail "T9KeyMap.swift is missing"

test -f "$SHARED_DICT" \
  || fail "SharedDictionaryStore.swift (voice<->keyboard dictionary bridge) is missing"

grep -q "AppGroup.id" "$SHARED_DICT" \
  || fail "SharedDictionaryStore must use the centralized App Group id"

grep -q "PinyinEngine" "$KEYBOARD" \
  || fail "Keyboard must host the pinyin engine"

grep -q "toggleLanguage" "$KEYBOARD" \
  || fail "Keyboard must expose a Chinese/English toggle"

grep -q "selectCandidate" "$KEYBOARD" \
  || fail "Keyboard must commit selected pinyin candidates"

grep -q "loadHotwordsIfNeeded" "$KEYBOARD" \
  || fail "Keyboard must inject shared hotwords into the pinyin engine"

grep -q "SharedDictionaryStore.publish" "$DICTATION" \
  || fail "Main app must publish the effective dictionary to the App Group for keyboard sync"

grep -q "SharedDictionaryStore.recordSelection" "$KEYBOARD" \
  || fail "Keyboard selections must feed the shared learned-word store"

grep -q "learnedWords(minimumCount: 2" "$ROOT/_sources/Shared/MobileSettingsStore.swift" \
  || fail "Repeated keyboard selections must be eligible for speech hotword context"

grep -q "typelessDictionaryImportVersion" "$ROOT/_sources/Shared/MobileSettingsStore.swift" \
  || fail "Typeless dictionary import must be versioned so user deletions remain respected"
grep -q '"LSQ Investment Fund SPC"' "$ROOT/_sources/Shared/MobileSettingsStore.swift" \
  || fail "Typeless business vocabulary must be included"
grep -q '"Disruptive Opportunity Fund I SP"' "$ROOT/_sources/Shared/MobileSettingsStore.swift" \
  || fail "The truncated Typeless fund name must use the project's full formal name"
grep -q '"metalpha"' "$ROOT/_sources/Shared/MobileSettingsStore.swift" \
  || fail "Typeless dictionary import must include the final screenshot entry"
grep -q "func addDictionaryWord" "$ROOT/_sources/Shared/MobileSettingsStore.swift" \
  || fail "Dictionary words must be addable as individual entries"
grep -q "func updateDictionaryWord" "$ROOT/_sources/Shared/MobileSettingsStore.swift" \
  || fail "Every dictionary entry must support editing"
grep -q "func deleteDictionaryWord" "$ROOT/_sources/Shared/MobileSettingsStore.swift" \
  || fail "Every dictionary entry must support persistent deletion"
grep -q "dictionaryWordCard" "$ROOT/_sources/App/Views.swift" \
  || fail "Dictionary UI must render one Typeless-style card per word"
grep -q 'Button("删除", role: .destructive)' "$ROOT/_sources/App/Views.swift" \
  || fail "An expanded dictionary card must expose an explicit delete action"

grep -q "_sources/Shared/SharedDictionaryStore.swift" "$ROOT/project.yml" \
  || fail "project.yml keyboard target must compile SharedDictionaryStore"

test -f "$ROOT/_sources/Keyboard/SharedKeyboardPreferenceStore.swift" \
  || fail "Keyboard layout preference store is missing"

test -f "$ROOT/tools/build_pinyin_dict.py" \
  || fail "Pinyin dictionary build script is missing"

# ---------- App Group 可用性 + 免费账号降级保留 ----------
APPGROUP="$ROOT/_sources/Shared/AppGroup.swift"
test -f "$APPGROUP" \
  || fail "AppGroup availability helper is missing"

grep -q "containerURL(forSecurityApplicationGroupIdentifier:" "$APPGROUP" \
  || fail "AppGroup must detect real availability via container URL (free accounts have no App Group)"

grep -q "AppGroup.suite" "$ROOT/_sources/Shared/PendingTextStore.swift" \
  || fail "PendingTextStore must route through AppGroup.suite (pasteboard fallback when unavailable)"

grep -q "AppGroup.suite" "$ROOT/_sources/Shared/KeyboardBridgeStore.swift" \
  || fail "KeyboardBridgeStore must route through AppGroup.suite"

grep -q "AppGroup.suite" "$ROOT/_sources/Shared/SharedDictionaryStore.swift" \
  || fail "SharedDictionaryStore must route through AppGroup.suite"

grep -q "_sources/Shared/AppGroup.swift" "$ROOT/project.yml" \
  || fail "project.yml keyboard target must compile AppGroup.swift"

grep -q "maxEntries" "$ENGINE_DIR/PinyinDictionary.swift" \
  || fail "PinyinDictionary must cap loaded entries to bound keyboard-extension memory"

grep -q "maxEntries = 50_000" "$ENGINE_DIR/PinyinDictionary.swift" \
  || fail "PinyinDictionary text fallback cap must remain 50,000 entries"

grep -q "dictionaryReady" "$KEYBOARD" \
  || fail "Keyboard must surface pinyin dictionary readiness (no silent failure)"

# ---------- Darwin 通知桥(仅 App Group 不可用时备用) ----------
DARWIN="$ROOT/_sources/Shared/DarwinBridge.swift"
test -f "$DARWIN" \
  || fail "DarwinBridge (cross-process signaling without App Group) is missing"

grep -q "CFNotificationCenterGetDarwinNotifyCenter" "$DARWIN" \
  || fail "DarwinBridge must use Darwin notification center (no App Group / entitlement needed)"

grep -q "_sources/Shared/DarwinBridge.swift" "$ROOT/project.yml" \
  || fail "project.yml keyboard target must compile DarwinBridge.swift"

grep -q "DarwinBridge.cmdStop" "$KEYBOARD" \
  || fail "Keyboard must send a remote stop command over Darwin"

grep -q "DarwinBridge.cmdStart" "$KEYBOARD" \
  || fail "Keyboard must resume recording without app switch when app is alive"

grep -q "handleFreeVoiceTap" "$KEYBOARD" \
  || fail "Keyboard must handle free-account voice taps via Darwin"

grep -q "DarwinBridge.cmdStop" "$DICTATION" \
  || grep -q "handleDarwinStop" "$DICTATION" \
  || fail "App must respond to the keyboard's Darwin stop command"

# ---------- iPhone 操作按钮/背面三击→全局语音输入 ----------
ACTION_INTENT="$ROOT/_sources/App/ActionCaptureIntent.swift"
test -f "$ACTION_INTENT" \
  || fail "Action-button App Intent is missing"

grep -q "struct StartTodoCaptureIntent: AppIntent" "$ACTION_INTENT" \
  || fail "Action-button capture must be exposed as an App Intent"

grep -q "struct VoicePenAppShortcuts: AppShortcutsProvider" "$ACTION_INTENT" \
  || fail "Action-button capture must be exposed as an App Shortcut"

grep -q 'shortTitle: "语音输入"' "$ACTION_INTENT" \
  || fail "Action-button shortcut must have a stable user-visible title"

grep -q "openAppWhenRun: Bool { false }" "$ACTION_INTENT" \
  || fail "Action-button recording must stay in the background and use its Live Activity"

grep -q "DarwinBridge.cmdCapture" "$ACTION_INTENT" \
  || fail "Action-button intent must signal an already-running app without polling delay"

grep -q "darwin.observe(DarwinBridge.cmdCapture)" "$DICTATION" \
  || fail "Dictation controller must consume action-button requests immediately"

grep -q "mode = .capture" "$DICTATION" \
  || fail "Action-button recordings must retain their dedicated global-dictation mode"

grep -q 'shouldCreateTodo = mode == .todoCapture || hitsTrigger' "$DICTATION" \
  && grep -q 'shouldDeliverText = mode == .keyboard || mode == .capture || !shouldCreateTodo' "$DICTATION" \
  || fail "Action dictation must only create todos on triggers while always delivering text"

grep -q 'PendingTextStore.copyToSystemPasteboard(deliveryText)' "$DICTATION" \
  && grep -q 'UIPasteboard.general.items = \[\[plainTextType: text\]\]' "$ROOT/_sources/Shared/PendingTextStore.swift" \
  || fail "Action dictation must publish cleaned plain text to the system pasteboard"

grep -q 'controller.mode = .todoCapture' "$ROOT/_sources/App/Views.swift" \
  || fail "The explicit todo-page microphone must remain a forced-todo entry"

grep -q '背面轻点三下' "$ROOT/_sources/App/Views.swift" \
  || fail "The app must explain how Back Tap reuses the global voice shortcut"

grep -q "captureHotSessionIdleTimeout: TimeInterval = 90" "$DICTATION" \
  || fail "Action-button capture must retain only the bounded 90-second warm-audio window"

grep -q 'mode == .keyboard || mode == .capture' "$DICTATION" \
  || fail "Action-button capture must use the warm recorder path for rapid repeat capture"

grep -q "emitDarwinState" "$DICTATION" \
  || fail "App must broadcast recording state over Darwin for the keyboard"

# ---------- Typeless 同款体验:热会话(暖态免跳转)+ 冷态跳转后自动跳回 ----------
grep -q "func stop(keepHot: Bool = false, preserveAudioSession: Bool = false)" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Recorder must support keep-hot stops for keyboard relay"

grep -q "var isHot: Bool { hotFlag && engine.isRunning }" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Recorder hot state must verify the engine is actually running (interruptions stop it)"
grep -q "var hasHotSessionIntent: Bool { hotFlag }" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Recorder must retain its hot-session intent for the legacy PiP path"

grep -q "guard shouldCapture" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Recorder must discard buffers while hot-idle to avoid unbounded memory growth"

# 靠热引擎的待命(2026-09-08 起只剩纯音频)只持有后台资格；真正录音始终由
# 前台预热的 Recorder 完成,不得以"机制已启动"假定麦克风必然正在产生样本。
grep -q "try recorder.warmUp()" "$DICTATION" \
  && grep -q "let wav = recorder.stop(keepHot: shouldKeepHot)" "$DICTATION" \
  && ! grep -q "beginCapturedMicrophoneRecording" "$DICTATION" \
  && ! grep -q "stopCapturedMicrophoneRecording" "$DICTATION" \
  || fail "hot-engine standby must keep a prewarmed Recorder as its only recording source"

grep -q "hotSessionIdleTimeout: TimeInterval = 600" "$DICTATION" \
  || fail "Hot session must expire after the 10-minute idle window"

# ---------- 冷启动自动返回必须可关(2026-09-08) ----------
# 这条路今天只能回硬编码的微信。在别的宿主里它把用户送错地方,比不返回更糟
# (§11.6 原话,当日真机三次复现)。宿主身份做通之前,开关不得被去掉;
# 守卫必须排在 maybeStartColdReturn 最前面,关掉后连"尝试"都不能发生。
grep -q 'var coldReturnEnabled = true' "$ROOT/_sources/Shared/MobileSettingsStore.swift" \
  || fail "cold return must stay user-switchable while the host is hardcoded"
grep -A4 "private func maybeStartColdReturn" "$DICTATION" \
  | grep -q "guard settings.coldReturnEnabled" \
  || fail "the cold-return opt-out must be checked before anything else in maybeStartColdReturn"
grep -q 'Toggle("口述后自动返回原 App"' "$ROOT/_sources/App/Views.swift" \
  || fail "the cold-return switch must be reachable from settings"

# ---------- 纯音频待命(2026-09-08 新增的第三套机制) ----------
# 用户在对照豆包并知情"橙点常亮"代价后,明确要求把它做成画中画之外的**显式选项**。
# 三条不可回退的性质:
#   1. 默认必须不变——`.auto` 仍解析为画中画,`usesAudioSession` 只由显式偏好触发;
#   2. 存活判据必须是真实引擎状态,不能只报"用户想待命"(§13.2 / §11.1);
#   3. 它不得引入任何非公开接口——这正是选它的唯一理由。
grep -q "case audioSession" "$ROOT/_sources/App/StandbyMechanism.swift" \
  && grep -q "preference == .audioSession" "$ROOT/_sources/App/StandbyMechanism.swift" \
  && grep -q "static var keepsRecorderHot: Bool" "$ROOT/_sources/App/StandbyMechanism.swift" \
  || fail "audio-session standby must exist as an explicit mechanism"

# ---------- ScreenCaptureKit 已按用户决定删除(2026-09-08) ----------
# 它 9/1 就因"每次新会话都要过系统共享选择器"结案(§11.1e-CLOSED),此后只是死选项;
# 纯音频待命已补上"公开 API 后台待命"这个位置。守卫防止它被无声加回来 ——
# 一并盯住 `screen-capture` 后台模式,那是会被审核看见的声明。
[[ ! -f "$ROOT/_sources/App/ScreenCaptureStandbyController.swift" ]] \
  || fail "ScreenCaptureKit standby was removed on 2026-09-08; do not resurrect it"
! grep -q "case screenCapture" "$ROOT/_sources/App/StandbyMechanism.swift" \
  && ! grep -q "ScreenCaptureStandbyController" "$ROOT/_sources/App/StandbyMechanism.swift" \
  && ! grep -q "canImport(ScreenCaptureKit)" "$ROOT/_sources/App/StandbyMechanism.swift" \
  || fail "standby mechanism picker must not offer ScreenCapture any more"
! /usr/libexec/PlistBuddy -c "Print :UIBackgroundModes" "$ROOT/_sources/App/Info.plist" \
  | grep -q "screen-capture" \
  || fail "screen-capture background mode must be gone with the SCK mechanism"
/usr/libexec/PlistBuddy -c "Print :UIBackgroundModes" "$ROOT/_sources/App/Info.plist" \
  | grep -q "audio" \
  || fail "audio background mode is required by both remaining standby paths"

grep -q "var isActive: Bool { armed && (isRecorderEngineLive?() ?? false) }" \
    "$ROOT/_sources/App/AudioSessionStandbyController.swift" \
  || fail "audio-session standby must report liveness from the real engine, never from intent alone"

grep -q "var isEngineLive: Bool { engine.isRunning }" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "Recorder must expose a hotFlag-independent engine liveness probe"

grep -q "AudioSessionStandbyController.shared.isRecorderEngineLive" "$DICTATION" \
  || fail "the engine liveness probe must be injected by DictationController"

# 纯音频这条路的全部价值就是"零非公开接口"。任何私有 selector 混进来都必须当场失败。
# 只看**代码**:注释里点名 setControlsStyle: 是在解释"为什么不用它",属于必要的
# 决策记录,不该被守卫误伤,所以先剥掉注释行再判。
! sed -e 's|//.*||' "$ROOT/_sources/App/AudioSessionStandbyController.swift" \
  | grep -qE "NSSelectorFromString|NSClassFromString|LSApplicationWorkspace|setControlsStyle" \
  || fail "audio-session standby must not reach for any non-public interface"

# stop() 不许自己拆 Recorder:录音中关待命会掐断用户正在说的这一段,
# 引擎拆除统一由 deactivateStandby 的 teardownWhenIdle 决定。
! sed -n '/^    func stop() {/,/^    }/p' \
    "$ROOT/_sources/App/AudioSessionStandbyController.swift" | grep -q "recorder" \
  || fail "audio-session standby stop() must not tear down the recorder itself"

# ---------- 免切换待命:前台预热 + 时长选择 + 灵动岛 + 中断/到期自动退出 ----------
grep -q "func warmUp() throws" "$ROOT/_sources/Shared/Recorder.swift" \
  || fail "standby must prewarm Recorder with sampling gate closed"
grep -q "case oneHour = \"1 小时\"" "$ROOT/_sources/Shared/MobileSettingsStore.swift" \
  || fail "standby must offer a one-hour duration"
grep -q "case eightHours = \"8 小时\"" "$ROOT/_sources/Shared/MobileSettingsStore.swift" \
  || fail "standby must offer an eight-hour duration"
grep -q "case untilInterrupted = \"直到被中断\"" "$ROOT/_sources/Shared/MobileSettingsStore.swift" \
  || fail "standby must offer an until-interrupted duration"
grep -q "if !standbyEnabled, recorder.isHot" "$DICTATION" \
  || fail "explicit standby must override the normal 10-minute teardown"
grep -q "case standby" "$ROOT/_sources/Shared/CaptureActivityAttributes.swift" \
  || fail "Live Activity must expose a distinct standby stage"
grep -q "voicepen://standby-stop" "$ROOT/_sources/LiveActivity/ShallWeTalkLiveActivity.swift" \
  || fail "standby Live Activity must expose a stop action"
# 2026-08-03:StandbyMethod 二选一(即时待命 / 画中画省电)已删除,待命恒为画中画。
# 这里反向断言,防止那套被加回来。只匹配真实声明/引用,不匹配注释里的历史说明。
#
# 2026-08-12 收窄:iOS 27 引入了**另一个维度**的选择 —— 后台待命机制到底走
# ScreenCaptureKit(公开 API,§11.1e)还是画中画(旧方案,依赖私有 setControlsStyle:)。
# 这与 2026-08-03 删掉的那个"省电档位"选择完全不是一回事,不应被同一条守卫误伤。
# 因此:旧语义(StandbyMethod / standbyMethodRaw / 即时待命)继续禁止;
# 新的机制选择器改为**正向断言**,并要求它必须被 iOS 27 版本门限包住。
! grep -q "^enum StandbyMethod" "$ROOT/_sources/Shared/MobileSettingsStore.swift" \
  && ! grep -q "standbyMethodRaw" "$ROOT/_sources/Shared/MobileSettingsStore.swift" \
  && ! grep -q "standbyMethodRaw" "$ROOT/_sources/App/Views.swift" \
  && ! grep -q "private var usesInstantStandby" "$DICTATION" \
  || fail "standby must not resurrect the old instant/power-saving method choice"

# 机制选择器必须存在。2026-09-08:原本要求它被 `#available(iOS 27.0, *)` 包住,
# 那是因为唯一的第二个选项 ScreenCaptureKit 是 iOS 27 专有的。SCK 删除后,
# 剩下的画中画与纯音频在全部支持的系统上都可用,版本门限随之作废 ——
# 这是跟着实现变化取消一条不再成立的断言,不是放宽守卫。
grep -q "Picker(\"待命机制\"" "$ROOT/_sources/App/Views.swift" \
  || fail "standby mechanism picker is missing"
grep -A6 "Picker(\"待命机制\"" "$ROOT/_sources/App/Views.swift" \
  | grep -q "Kind.audioSession.rawValue" \
  || fail "standby mechanism picker must offer the audio-session option"
grep -A6 "Picker(\"待命机制\"" "$ROOT/_sources/App/Views.swift" \
  | grep -q "Kind.pictureInPicture.rawValue" \
  || fail "standby mechanism picker must keep picture-in-picture as the default path"

# 2026-09-08:此处原有一整组 ScreenCaptureKit 专属守卫(canImport 包裹、microphone
# output 挂接、full-display capture、2x2 分辨率、单一启动所有者)。SCK 实现已按用户
# 决定删除,这些断言的目标文件不复存在,随实现一起移除 —— 上面已新增反向守卫
# 防止它被加回来。仍然成立的那部分(热引擎语义、stopAll)保留在下面。
grep -q "if recorder.isHot { return true }" "$DICTATION" \
  && grep -q "try recorder.warmUp()" "$DICTATION" \
  && grep -q "let mechanismKeepsHot = standbyEnabled && StandbyController.keepsRecorderHot" "$DICTATION" \
  && ! grep -q "capturedMicrophoneReady" "$DICTATION" \
  && ! grep -q "beginCapturedMicrophoneRecording" "$DICTATION" \
  || fail "hot-engine standby must keep a prewarmed Recorder as the only recording source"
# `.auto` 必须解析为画中画。2026-08-13 用户拍板日常走画中画,2026-09-08 删除 SCK 后
# 这条依然是默认行为的锁 —— 新增的纯音频机制同样只能由用户显式选择进入。
# 判据必须是**精确等于** .audioSession,不能是 "!= .pictureInPicture" 之类的默认包含写法 ——
# 后者会让 .auto 悄悄落进纯音频,把一个橙点常亮的机制变成默认行为。
grep -q "preference == .audioSession" "$ROOT/_sources/App/StandbyMechanism.swift" \
  && grep -A2 "static var shared: any StandbyMechanism {" "$ROOT/_sources/App/StandbyMechanism.swift" \
     | grep -q "return PictureInPictureStandbyController.shared" \
  || fail "auto must keep resolving to picture-in-picture, never to an opt-in mechanism"
# 偏好改变后不能按新偏好只停一个实现,否则旧机制会留下界面不可见的孤儿会话。
# 教训来自 SCK 时代(build 130),但对画中画↔纯音频同样成立:切走之后 `shared` 已经
# 解析成新实现,旧那个再也收不到 stop —— 画中画会留一个还在供帧的 PiP,
# 纯音频会留一条还占着麦克风、橙点还亮着的会话。
grep -q "static func stopAll()" "$ROOT/_sources/App/StandbyMechanism.swift" \
  && grep -A4 "static func stopAll()" "$ROOT/_sources/App/StandbyMechanism.swift" \
     | grep -q "PictureInPictureStandbyController.shared.stop()" \
  && grep -A4 "static func stopAll()" "$ROOT/_sources/App/StandbyMechanism.swift" \
     | grep -q "AudioSessionStandbyController.shared.stop()" \
  && grep -q "standbyMechanismPreferenceDidChange" "$ROOT/_sources/App/Views.swift" \
  || fail "switching standby mechanisms must stop every implementation, not just the current preference"
# 2026-09-08:原本这里要求 Info.plist 声明 `screen-capture`(SCK 缺它会被 -3824 停掉)。
# SCK 已删除,该声明随之移除 —— 后台模式是审核会看的声明,不留没有实现支撑的项。
# 反向守卫在上面「ScreenCaptureKit 已按用户决定删除」那一段。

# 键盘唤起录音时必须自动开启免切换待命,且必须在**起录成功之后立即**触发一次——
# 画中画要求 source view 已入窗口,冷启动 openURL 那一刻界面还没布局完拿不到;
# 挪到录完之后则"第一次点键盘"这一趟白跑,达不到用户要的"点一次就进入待命"。
grep -q "func autoEnableKeyboardStandbyIfNeeded" "$DICTATION" \
  && grep -q "DiagLog.log(\"start\", \"起录成功" "$DICTATION" \
  && grep -A3 "DiagLog.log(\"start\", \"起录成功" "$DICTATION" | grep -q "autoEnableKeyboardStandbyIfNeeded()" \
  || fail "standby must be armed right after recording starts, not only after it finishes"
# 2026-08-04 二次修正(build 70):本处原先断言"冷启动永远不会变成 .active,所以不得要求
# .active"。那个结论来自在 arm 时刻**采样** applicationState 全是 1;build 69 加上
# didBecomeActive 打点后,真机三次冷启动都在 +429/+434ms 稳定变成 .active。
# 放宽到 .inactive 的真实代价:起录成功(≈+350ms)时还差 76ms,这次 startPictureInPicture
# 必被 AVKit 以 -1001 拒绝,重建后的那次要 2.4 秒才 active、甚至 11 秒超时。
# 因此现在反过来要求 .active,并且必须存在 didBecomeActive 驱动的 arm 来兑现这个要求。
grep -q "guard state == .active else" "$DICTATION" \
  || fail "auto standby must request PiP only while .active (-1001 otherwise)"
grep -q "func armKeyboardStandbyOnActivation" "$DICTATION" \
  && grep -q "UIApplication.didBecomeActiveNotification" "$DICTATION" \
  || fail "requiring .active needs a didBecomeActive-driven arm, or the cold path never arms"
# 放宽前台守卫的开关必须独立于 duringRecording。二者复用同一个参数时,arm 恰好发生在
# phase 尚未变成 .recording 的瞬间就会退回 .active 守卫,自动开启永远失败(2026-08-04 实测)。
grep -q "allowInactiveForeground ? appState != .background : appState == .active" "$DICTATION" \
  || fail "the foreground relaxation must key off allowInactiveForeground, not duringRecording"
grep -q "activateStandby(duringRecording: recording, allowInactiveForeground: true)" "$DICTATION" \
  || fail "the keyboard auto path must pass allowInactiveForeground"
# 冷启动时 Link 会同时 openURL 和写桥请求/发信令。openURL 是唯一合法起录来源,已经起录后
# 冷路径守卫绝不能再把 .recording 覆盖成 .error——那会让用户必须点第二次(2026-08-04 实测)。
# 因此去重/在录判断必须排在冷路径守卫之前。
grep -q "Darwin start 忽略:openURL 已在起录" "$DICTATION" \
  && grep -q "桥 record 忽略重复" "$DICTATION" \
  || fail "cold-path guard must not clobber a recording already started via openURL"
# 录音期间建立待命绝不能拆录音引擎,否则会掐断用户正在说的这一段。
grep -q "if !duringRecording { recorder.teardown() }" "$DICTATION" \
  || fail "arming standby during a recording must not tear down the recorder"
grep -q "AVPictureInPictureController.ContentSource" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  || fail "PiP standby must use the public AVKit content-source API"
grep -q "activeVideoCallSourceView: sourceView" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  && grep -q "contentViewController: videoCallContentViewController" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  && grep -q "AVPictureInPictureVideoCallViewController" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  && grep -q "AVSampleBufferDisplayLayer" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  || fail "PiP standby must host the Typeless-style sample-buffer renderer in a real video-call content source"
grep -q "frameWidth = 5040" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  && grep -q "frameHeight = 1" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  && grep -q "frameInterval: TimeInterval = 2" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  && grep -q "playbackRate: Float64 = 0.5" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  || fail "PiP standby must reproduce the observed 5040x1 half-speed Typeless geometry"
grep -q "homeKitCameraControlsStyle = 3" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  && grep -q "videoCallControlsStyle = 4" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  && grep -q 'NSSelectorFromString("setControlsStyle:")' "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  && grep -q "scheduleTypelessControlsStyleTransition" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  || fail "PiP standby must reproduce Typeless's observed HomeKitCamera-to-VideoCall controls-style sequence"
grep -q "lastPiPControlsStyleDiagnostic" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  || fail "PiP controls-style transition must remain independently inspectable after lifecycle logs"
[[ "$(grep -c "scheduleTypelessControlsStyleTransition" "$ROOT/_sources/App/PictureInPictureStandbyController.swift")" -ge 3 ]] \
  || fail "Video-call PiP must switch controls style after active polling even when didStart is omitted"
grep -q "recoverFromUnexpectedSystemStop" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  && grep -q "interruption assertion 内已请求重启 PiP" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  && grep -q "isRecoveringUnexpectedSystemStop" "$ROOT/_sources/App/DictationController.swift" \
  || fail "Camera/system PiP stops must use the transient interruption assertion for bounded recovery"
! grep -q "stashAssistDuration\|switchFrameGeometry\|scheduleUltraWideTransition" \
  "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  || fail "PiP must not restore the disproven manual stash transition"
grep -q "pictureInPictureControllerShouldProhibitBackgroundAudioPlayback" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  || fail "PiP standby must not start background audio playback"
grep -q "sessionGeneration" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  && grep -q "requestedGeneration" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  && grep -q "pictureInPictureController === controller" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  || fail "PiP standby must reject callbacks from invalidated controller generations"
grep -q "guard hasValidSession else { return }" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  && grep -q "忽略过期 PiP didStart" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  && grep -q "忽略过期 PiP didStop" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  || fail "PiP standby must not resurrect a stopped session during lifecycle recovery"
grep -q "bufferedMediaLead = CMTime(value: 6" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  && grep -q "requestMediaDataWhenReady(on: .main)" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  || fail "PiP standby must keep a renderer-driven buffer ahead of background timer jitter"
grep -q "requiresFlushToResumeDecoding" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  && grep -q "flush(removingDisplayedImage: false)" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  && grep -q "nextPTSBeforeFlush" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  || fail "PiP renderer recovery must preserve the invisible image and monotonic timeline"
grep -q "kCMSampleAttachmentKey_DisplayImmediately" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  && grep -q "displayImmediately: true" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  && grep -q "immediateReseed=" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  || fail "PiP recovery must immediately reseed the 5040x1 image at the current timebase"
! grep -q "renderer.flush()" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  || fail "PiP interruption recovery must not use an image-removing unqualified flush"
grep -q "PictureInPictureStandbySourceView" "$ROOT/_sources/App/VoicePenMobileApp.swift" \
  || fail "The sample-buffer source must stay attached to the root app window"
if grep -q 'NSSelectorFromString("suspend")' "$ROOT/_sources/App/PictureInPictureStandbyController.swift"; then
  fail "PiP standby must not restore the abandoned private cold-return path"
fi
grep -q "lastPiPDiagnostic" "$ROOT/_sources/App/PictureInPictureStandbyController.swift" \
  || fail "PiP startup diagnostics must survive even if file logging is unavailable"
grep -q "requestStartFromUserAction" "$DICTATION" \
  || fail "PiP must be requested synchronously from the user's Toggle/Picker event"
# 2026-08-03:原本这里断言 Views 持有 @AppStorage("standbyMethod"),用途是"切换待命方式时
# 设置页立即重绘"。方式选择器已删除(待命恒为画中画),该断言随之作废,不再替换——
# 上面 requestStartFromUserAction 的断言已覆盖"必须从用户事件栈同步请求画中画"这条关键约束。
if grep -q "standbyControl" "$ROOT/_sources/App/Views.swift"; then
  fail "Standby controls must live in Settings, not as a horizontal bar on the Record screen"
fi

# ---------- 冷启动:全程在 App 内录音,停录后回宿主投递(2026-07-11 终稿,不再自动跳回)----------
# 保留的防塌缩去重(与自动跳回实验无关,仍是真实需要的护栏)
grep -q "忽略过早 stop" "$DICTATION" \
  || fail "Bridge must suppress a too-early stop that would collapse a sub-second recording"

# 2026-08-04:该分支合并了"在录/整理中"判断并提到冷路径守卫之前,日志措辞随之改变。
grep -q "桥 record 忽略重复" "$DICTATION" \
  || fail "Bridge must dedup rapid duplicate record requests while starting"

# ---------- 冷启动竞态修复:桥/Darwin 不驱动冷起录 + 扩宽 needsForeground 到非前台活跃 + 瞬时重试 ----------
# start() 必须带来源(区分 openURL 前台起录 vs 桥/Darwin 后台请求),桥/Darwin 冷路径不得起录
grep -q "func start(source: StartSource)" "$DICTATION" \
  || fail "start() must take a StartSource so the bridge/Darwin cold path can be distinguished from openURL"
grep -q "start(source: .openURL)" "$DICTATION" \
  || fail "openURL foreground launch must be the sole cold-path starter (source=.openURL, exempt from the cold guard)"
grep -q "start(source: .bridge)" "$DICTATION" \
  || fail "Paid bridge record must start via source=.bridge"
# 冷路径守卫必须判 != .active(覆盖 .inactive 与 .background),不能只判 == .background(会漏掉 URL 拉起瞬间的 .inactive)
grep -q "applicationState != .active" "$DICTATION" \
  || fail "Cold-start guard must broaden to applicationState != .active (covers .inactive AND .background)"
! grep -q "applicationState == .background" "$DICTATION" \
  || fail "Cold-start guard must no longer key off .background only (that missed the .inactive foreground-launch window)"
# 冷激活瞬时失败(输入未就绪 / '!int')要退会话后重试一次
grep -q "startRecorderWithColdRetry" "$DICTATION" \
  || fail "Cold activation must retry once after deactivating the session (input-not-ready / cannotInterruptOthers window)"
grep -q "isTransientColdStartError" "$DICTATION" \
  || fail "Cold retry must be gated to transient errors (no-input / '!int')"
# '!int' 是后台激活非混音会话被拒，不应误报为“其他 App 占麦”。
grep -q "系统不允许 App 在后台重新激活麦克风" "$DICTATION" \
  || fail "cannotInterruptOthers ('!int') must report the background activation restriction honestly"

# 冷启动 UX:App 内可用的录音/停止按钮——录音坞 action 仍走 controller.toggle(),
# 录音键(RecordButton,已抽到 DesignSystem.swift)在录音态显示 stop.fill 停止图标
grep -q "controller.toggle()" "$ROOT/_sources/App/Views.swift" \
  || fail "RecordView dock must still drive the in-app start/stop via controller.toggle()"
grep -q "stop.fill" "$ROOT/_sources/App/Views.swift" \
  || fail "RecordButton must show a stop glyph while recording (in-app stop)"

# 停录后的诚实提示:文字已就绪、返回宿主才投递(不得再暗示"必须先返回才能录音")
grep -q "文字已就绪,返回刚才的应用即可插入" "$ROOT/_sources/App/Views.swift" \
  || fail "RecordView post-stop hint must honestly say text is ready and returning delivers it"

# 录音进行中要有明确指示:录音坞「正在聆听 · 识别中」+ 顶部实时草稿卡
grep -q "正在聆听 · 识别中" "$ROOT/_sources/App/Views.swift" \
  || fail "Recording dock must show an unmistakable in-progress label"
grep -q "LiveDraftCard" "$ROOT/_sources/App/Views.swift" \
  || fail "Memo feed must show a live draft card while recognizing"

# 录音是全局状态:非记录页由全局悬浮条兜底(单一指示,不与记录页录音坞叠加)
grep -q "struct GlobalRecordingBar" "$ROOT/_sources/App/Views.swift" \
  || fail "A global recording bar must exist so recording feedback shows on any tab"
grep -q "GlobalRecordingBar()" "$ROOT/_sources/App/VoicePenMobileApp.swift" \
  || fail "Root view must overlay the global recording bar above the TabView"
grep -q "tab != .record" "$ROOT/_sources/App/VoicePenMobileApp.swift" \
  || fail "Global overlay must be suppressed on the home tab to avoid double indicators with the dock"

# ---------- 修复:待办语音加提醒识别完却没入待办列表(桥 tick 悄悄把 mode 从 .capture 改成 .keyboard)----------
# 根因修复:tickKeyboardBridge 在已有非键盘会话(mode!=.keyboard 且 phase 忙)时,必须延后处理桥请求,
# 绝不能推进到 mode = .keyboard 那一行,否则 finish() 的待办路由判断会被静默改写
grep -q "isForeignSession" "$DICTATION" \
  || fail "tickKeyboardBridge must defer bridge requests while a non-keyboard session is active (must not stomp mode)"
# 诊断自检:待办路由判断落一行日志,mode 若被改写会在真机日志里现形
grep -q "路由判断 mode=" "$DICTATION" \
  || fail "finish() must log the todo-routing decision (mode + trigger match) for on-device self-diagnosis"
# 待办页的旧麦克风按钮录音/整理中禁用:非记录页唯一可操作的停止控件是 GlobalRecordingBar
grep -q ".disabled(controller.phase == .recording || controller.phase == .processing)" "$ROOT/_sources/App/Views.swift" \
  || fail "Todo toolbar mic button must disable while recording/processing so the global bar is the single stop control"

# 原音留档 + 播放:后台原子写入 WAV(不阻塞文字/不依赖转码 XPC)、删记录连音频删
grep -q "archiveAudio" "$ROOT/_sources/Shared/HistoryStore.swift" \
  || fail "HistoryStore must archive source audio"
grep -q "try wav.write(to: dst, options: .atomic)" "$ROOT/_sources/Shared/HistoryStore.swift" \
  || fail "Audio archival must use a bounded, reliable atomic file write"
grep -q "maxAudioBytes" "$ROOT/_sources/Shared/HistoryStore.swift" \
  || fail "Audio archive must be capped/pruned to a storage budget"
grep -q "history.archiveAudio(wav, id:" "$DICTATION" \
  || fail "finish() must tee the finished WAV to the background audio archiver (additive, off the text path)"
grep -q "play.fill" "$ROOT/_sources/App/Views.swift" \
  || fail "Records with audio must expose a play button"
# 回放与录音会话隔离:录音/整理进行中拦截回放
grep -q "guard !blocked" "$ROOT/_sources/App/AudioPlayback.swift" \
  || fail "Audio playback must never activate while a recording is in progress"

# 死实验代码已彻底移除:宿主探测、S1-S4 返回矩阵、私有 suspend/面包屑、责任链开容器、手动返回旗标
test ! -e "$ROOT/_sources/Keyboard/HostAppIdentity.swift" \
  || fail "Disabled HostAppIdentity experiment must not ship in the keyboard extension"
! grep -q "hostAppBundleID\|hostAppRecordedAt\|hostAppProbeNote" "$BRIDGE" \
  || fail "Bridge snapshot must drop disabled host-probe state"
! grep -q "requestRecording(hostBundleID:" "$KEYBOARD" \
  || fail "Keyboard record request must no longer carry a probed host id"
! grep -q "attemptColdReturn\|resolveColdReturnStrategy\|coldReturnCycle\|hostReturnSchemes\|attemptBreadcrumbReturn\|_returnToPreviousApp\|awaitingManualReturn\|autoReturnAfterStart" "$DICTATION" \
  || fail "App cold-return experiment matrix (S1-S4 / breadcrumb / manual-return flag) must be fully removed"
! grep -q "NSSelectorFromString(\"suspend\")" "$DICTATION" \
  || fail "Private suspend return call must be removed"
! grep -q "ColdReturnStrategy\|sceneDestruction\|sendActionSuspend\|performSuspend" \
    "$ROOT/_sources/App/ColdReturnCoordinator.swift" "$ROOT/_sources/Shared/MobileSettingsStore.swift" \
  || fail "Proven-failed cold-return strategy matrix must not ship"
! grep -q 'com.tencent.xin' "$ROOT/_sources/App/ColdReturnCoordinator.swift" \
  && grep -q "target.isValidForReturn" "$ROOT/_sources/App/ColdReturnCoordinator.swift" \
  && grep -q "hasFreshAudio()" "$ROOT/_sources/App/ColdReturnCoordinator.swift" \
  || fail "Cold return must validate a dynamic request target and real audio, never a fixed host"
! grep -q "startProbe\|endProbe\|灵动岛自检" \
    "$ROOT/_sources/App/CaptureLiveActivityController.swift" "$ROOT/_sources/App/Views.swift" \
  || fail "Resolved Live Activity probe must not ship as a permanent user-facing diagnostic"
! grep -q "awaitingManualReturn" "$ROOT/_sources/App/Views.swift" \
  || fail "RecordView must drop the old swipe-back-to-record framing"

# ---------- 单行五键录音行：52pt 录音键 + 4×46pt 功能键 ----------
grep -q "static let height: CGFloat = 52" "$QUIET_INK_COMPONENTS" \
  && grep -q "static let cornerRadius: CGFloat = 15" "$QUIET_INK_COMPONENTS" \
  && grep -q "QuietInkVoiceControlPalette" "$QUIET_INK_COMPONENTS" \
  || fail "Compact record key must keep the 52pt/r15 geometry and dedicated tokens"
grep -q "voiceControlAreaHeight: CGFloat = 66" "$KEYBOARD" \
  && grep -q "voiceKeyboardHeight: CGFloat = 66" "$KEYBOARD" \
  || fail "Voice face must use the compact single-row height"
grep -Fq "button.widthAnchor.constraint(equalToConstant: 46)" "$KEYBOARD" \
  && grep -Fq "voiceEditButton.leadingAnchor.constraint(equalTo: voiceSwitchButton.trailingAnchor, constant: 6)" "$KEYBOARD" \
  && grep -Fq "voiceEntry.leadingAnchor.constraint(equalTo: voiceEditButton.trailingAnchor, constant: 8)" "$KEYBOARD" \
  && grep -Fq "voiceEntry.trailingAnchor.constraint(equalTo: voiceDeleteButton.leadingAnchor, constant: -8)" "$KEYBOARD" \
  && grep -Fq "voiceDeleteButton.trailingAnchor.constraint(equalTo: voiceSendButton.leadingAnchor, constant: -6)" "$KEYBOARD" \
  || fail "Voice control row must use the 6/8/8/6 spacing grid"
grep -q "constant: -8" "$KEYBOARD" \
  && grep -q "constant: 8" "$KEYBOARD" \
  && grep -q "constant: -4" "$KEYBOARD" \
  || fail "Record key hit area must expand 8pt horizontally and 4pt vertically"
grep -q "state: .processing" "$KEYBOARD" \
  && grep -q "ForEach(0..<3" "$QUIET_INK_COMPONENTS" \
  || fail "Processing state must render the three-dot compact indicator"

grep -q "editableInsertedText" "$KEYBOARD" \
  && ! grep -q "lastKnownCanSendDirectly" "$KEYBOARD" \
  && grep -q "editableInsertedText?.isEmpty == false" "$KEYBOARD" \
  && grep -q "voicepen://edit" "$KEYBOARD" \
  && grep -q "requestID.hasPrefix(\"edit:\")" "$DICTATION" \
  || fail "Modify must remain available for the last inserted text beyond the heartbeat TTL"

# ---------- 共享诊断日志(真机排障:两进程写入 App Group,App 内查看/复制) ----------
DIAGLOG="$ROOT/_sources/Shared/DiagLog.swift"
test -f "$DIAGLOG" \
  || fail "DiagLog shared diagnostic logger is missing"

grep -q "queue.async" "$DIAGLOG" \
  || fail "DiagLog writes must be async off the critical path (keyboard must never block)"

grep -q "compact" "$DIAGLOG" \
  || fail "DiagLog must rotate/compact the log file to cap its size"

grep -q "_sources/Shared/DiagLog.swift" "$ROOT/project.yml" \
  || fail "project.yml keyboard target must compile DiagLog.swift"

grep -q "DiagLog.log" "$KEYBOARD" \
  || fail "Keyboard must log voice-bridge decision snapshots for diagnostics"

grep -q "DiagLog.log" "$DICTATION" \
  || fail "Dictation controller must log start/finish/bridge/interruption diagnostics"

grep -q "DiagLogView" "$ROOT/_sources/App/Views.swift" \
  || fail "Settings must expose the in-app diagnostic log viewer"

grep -q "复制全部" "$ROOT/_sources/App/Views.swift" \
  || fail "Diagnostic log viewer must offer copy-all for sending logs back"

# ---------- VAD 静音自动停(含键盘模式,默认 4 秒)----------
grep -q "秒自动停" "$DICTATION" \
  || fail "VAD must auto-stop on silence (incl. keyboard mode) and log it"
grep -q "if settings.vadEnabled, hasDetectedSpeech" "$DICTATION" \
  || fail "VAD auto-stop must remain enabled for keyboard mode after speech is detected"
grep -q "vadSilenceSeconds = 4" "$ROOT/_sources/Shared/MobileSettingsStore.swift" \
  || fail "Default VAD silence threshold must be 4 seconds"

# ---------- 起录延迟:Darwin kick 让 App 免等 0.5s 轮询立即接单 ----------
grep -q "cmdKick" "$ROOT/_sources/Shared/DarwinBridge.swift" \
  || fail "DarwinBridge must define the cmdKick wake signal"
grep -q "DarwinBridge.post(DarwinBridge.cmdKick)" "$ROOT/_sources/Shared/KeyboardBridgeStore.swift" \
  || fail "Keyboard bridge requests must post cmdKick so the app wakes without waiting for its poll tick"
grep -q "observe(DarwinBridge.cmdKick)" "$DICTATION" \
  || fail "App must observe cmdKick and process the pending bridge request immediately"

# ---------- iCloud 历史同步实到位(容器已进 entitlements + 同步实现)----------
grep -q "forUbiquityContainerIdentifier" "$ROOT/_sources/Shared/CloudHistorySync.swift" \
  || fail "CloudHistorySync must resolve the iCloud ubiquity container"
grep -q "ubiquitousItemDownloadingStatus != .current" "$ROOT/_sources/Shared/CloudHistorySync.swift" \
  || fail "Cloud pull must not synchronously read an iCloud item whose contents are not downloaded"
grep -q "com.apple.developer.ubiquity-container-identifiers" "$APP_ICLOUD_ENTITLEMENTS" \
  || fail "App.iCloud.entitlements must declare the ubiquity container (iCloud Documents)"

# ---------- 已绑定日历的待办：自动整理和手动编辑都必须同步 ----------
TODO_STORE="$ROOT/_sources/Shared/TodoStore.swift"
VIEWS="$ROOT/_sources/App/Views.swift"
grep -q "func updateTodoText" "$DICTATION" \
  || fail "Controller must provide a calendar-aware manual todo edit path"
grep -q "controller.updateTodoText" "$VIEWS" \
  || fail "Todo card manual saves must use the calendar-aware edit path"
grep -q "func upsert(todo: TodoItem, plan: TodoCalendarPlan?)" "$TODO_STORE" \
  || fail "Calendar sync must update an existing event even when edited text no longer contains a date"
grep -q "scheduledTodos.contains(where: { \$0.calendarEventIdentifier != nil })" "$DICTATION" \
  || fail "Automatic refinement must resync every already-bound calendar event"

# ---------- 个人词典 + 纠错对跨设备同步(2026-07-18):键盘扩展不直接碰 iCloud ----------
DICT_SYNC_CORE="$CORE/DictionarySync.swift"
DICT_SYNC_BRIDGE="$ROOT/_sources/Shared/DictionarySyncBridge.swift"
DICT_SYNC_COORDINATOR="$ROOT/_sources/Shared/DictionarySyncCoordinator.swift"

test -f "$DICT_SYNC_CORE" \
  || fail "Core dictionary sync merge semantics (DictionarySync.swift) are missing"
test -f "$DICT_SYNC_BRIDGE" \
  || fail "iCloud dictionary sync bridge (DictionarySyncBridge.swift) is missing"
test -f "$DICT_SYNC_COORDINATOR" \
  || fail "Dictionary sync coordinator (DictionarySyncCoordinator.swift) is missing"

grep -q "forUbiquityContainerIdentifier\|CloudHistorySync.containerID" "$DICT_SYNC_BRIDGE" \
  || fail "DictionarySyncBridge must resolve the shared iCloud ubiquity container"
grep -q "ubiquitousItemDownloadingStatus != .current" "$DICT_SYNC_BRIDGE" \
  || fail "Dictionary sync pull must not synchronously read an iCloud item whose contents are not downloaded"

# 键盘扩展只显式列出自己需要编译的文件(见本文件顶部的 project.yml VoicePenKeyboard target),
# 不像主 App 那样整目录收录 _sources/Shared——新增的两个 iCloud 桥接文件绝不能出现在其中。
! grep -q "_sources/Shared/DictionarySyncBridge.swift" "$ROOT/project.yml" \
  || fail "Keyboard extension must not compile DictionarySyncBridge.swift (no direct iCloud access)"
! grep -q "_sources/Shared/DictionarySyncCoordinator.swift" "$ROOT/project.yml" \
  || fail "Keyboard extension must not compile DictionarySyncCoordinator.swift (no direct iCloud access)"
! grep -q "import CloudKit" "$KEYBOARD" \
  || fail "Keyboard must never import CloudKit"
! grep -q "forUbiquityContainerIdentifier" "$KEYBOARD" \
  || fail "Keyboard must never touch the iCloud ubiquity container directly; the main app mirrors sync results into the App Group"

# ---------- 会议录音：单会话状态、物理路由恢复、音频完整性 ----------
MEETING_CONTROLLER="$ROOT/_sources/App/MeetingRecordingController.swift"
MEETING_VIEWS="$ROOT/_sources/App/MeetingViews.swift"
VOLC_FILE_TRANSCRIPTION="$CORE/VolcFileTranscription.swift"

test -f "$MEETING_CONTROLLER" \
  && test -f "$MEETING_VIEWS" \
  || fail "Meeting recording controller and recording view must exist"

grep -q "case starting" "$MEETING_CONTROLLER" \
  && grep -q "phase = .starting" "$MEETING_CONTROLLER" \
  && grep -q "guard phase == .idle else" "$MEETING_CONTROLLER" \
  || fail "Meeting start must lock a single active session before asynchronous recorder setup"

grep -q "reason == .oldDeviceUnavailable || reason == .newDeviceAvailable" "$MEETING_CONTROLLER" \
  && grep -q "忽略会话内部路由变化" "$MEETING_CONTROLLER" \
  && grep -q "isTransitioningSegment" "$MEETING_CONTROLLER" \
  || fail "Meeting route recovery must ignore self-generated session changes and serialize physical-route recovery"

grep -q "liveTranscript" "$MEETING_CONTROLLER" \
  && grep -q "MeetingRecordingSessionView" "$MEETING_VIEWS" \
  && grep -q "结束会议" "$MEETING_VIEWS" \
  || fail "An active meeting must show a dedicated transcript and explicit stop control"

grep -q "wav.count > 44" "$MEETING_CONTROLLER" \
  && grep -q "没有采集到可转写的音频" "$MEETING_CONTROLLER" \
  || fail "Empty meeting WAV files must be reported as capture failure, not processed as a successful transcript"

# 会议录音必须独占音频会话：PiP/待命的一次延迟重试、前台回调或掉线重建都不得
# 在会议进行时重新配置 AVAudioSession，否则会制造 PCM 黑洞。
grep -A12 "func yieldAudioForMeeting" "$DICTATION" | grep -q "standbyArmRetryTask?.cancel()" \
  && grep -A12 "func yieldAudioForMeeting" "$DICTATION" | grep -q "StandbyController.stopAll()" \
  && grep -A6 "private func tryArmStandby" "$DICTATION" | grep -q "MeetingRecordingController.shared.isActive" \
  && grep -A12 "private func handleStandbyPictureInPictureLoss" "$DICTATION" | grep -q "会议录音中忽略 PiP 掉线恢复" \
  && grep -A35 "try await StandbyController.shared.start()" "$DICTATION" | grep -q "回收迟到完成的待命启动" \
  || fail "Meeting recording must block queued, lifecycle, and PiP-recovery standby activation"

grep -q "拒绝起录：无法创建段落音频文件" "$MEETING_CONTROLLER" \
  && grep -q "sealCompleteAudioArchive" "$MEETING_CONTROLLER" \
  && grep -q "completeAudioArchiveForExport" "$MEETING_CONTROLLER" \
  && grep -q "record.state == .needsFinalize" "$MEETING_CONTROLLER" \
  && grep -q "combineWAVSegments" "$ROOT/_sources/Shared/MeetingAudioWriter.swift" \
  && grep -q "保存完整录音" "$MEETING_VIEWS" \
  || fail "Meeting recording must persist and export complete WAV before any transcription or summary"

grep -q 'ssd_version.*"200"' "$VOLC_FILE_TRANSCRIPTION" \
  && grep -q '"enable_ddc": false' "$VOLC_FILE_TRANSCRIPTION" \
  && grep -q '"language": "zh-CN"' "$VOLC_FILE_TRANSCRIPTION" \
  || fail "Meeting file transcription must use the faithful long-meeting ASR configuration"

# 合并语义:core 包纯函数必须覆盖 LWW / 墓碑防复活 / 三方并集 / 按时间截断(见 DictionarySyncTests.swift)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path "$CORE_DIR" --scratch-path "$CORE_SCRATCH" \
    --filter DictionarySyncTests \
  || fail "Dictionary/correction sync merge semantics regressed (LWW, tombstone anti-revival, union, truncation)"

HOST_RETURN_SMOKE_BIN="${TMPDIR:-/tmp}/voicepen-host-return-smoke"
xcrun swiftc -parse-as-library \
  "$BRIDGE" "$ROOT/_sources/Shared/PendingTextStore.swift" \
  "$ROOT/_sources/Shared/HostFieldKind.swift" "$ROOT/tests/HostReturnPolicySmoke.swift" \
  -o "$HOST_RETURN_SMOKE_BIN"
"$HOST_RETURN_SMOKE_BIN"
rm -f "$HOST_RETURN_SMOKE_BIN"

echo "PASS: keyboard voice entry regression checks"

! grep -Fq 'setHostMarkedText(showLive ? snapshot.liveText' "$KEYBOARD" \
  || fail "Voice ASR drafts must not write into the host field"
! grep -q 'pendingExplicitInsertionID' "$KEYBOARD" \
  || fail "Completed voice delivery must not hijack the next recording tap"

# Repainting a persisted inserted state must not replay success haptics.
python3 - "$KEYBOARD" <<'PYTEST'
import sys
from pathlib import Path
s = Path(sys.argv[1]).read_text()
render = s.split('private func updateVoiceButton(', 1)[1].split('private func showInsertedConfirmation()', 1)[0]
assert 'showInsertedConfirmation()' not in render
assert 'notificationOccurred' not in render and 'impactOccurred' not in render
success = s.split('if case .inserted(let text) = consumption {', 1)[1].split('return true', 1)[0]
assert success.count('showInsertedConfirmation()') == 1
print('PASS: persisted result rendering is silent; successful consumption emits one confirmation')
PYTEST

# Voice input must never force the user's foreground app to change.
python3 - "$ROOT/_sources/App/ActionCaptureIntent.swift" <<'PY_CHECK'
import pathlib, sys
s = pathlib.Path(sys.argv[1]).read_text().split("struct StartNoteCaptureIntent:", 1)[1].split("extension StartNoteCaptureIntent:", 1)[0]
assert "continueInForeground(" not in s, "Voice input unexpectedly forces foreground"
assert "[.background]" in s
assert "ReturnsValue<String>" in s
assert 'return .result(value: "")' in s
print("PASS: voice shortcut stays background and exposes text output")
PY_CHECK
