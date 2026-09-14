import SwiftUI
import UniformTypeIdentifiers
import ShallWeTalkCore
import Combine

// MARK: - 页 1「记录」= 录音 + 备忘
//
// 结构参照系统「语音备忘录」:一条可滚动的备忘流(即口述历史)+ 底部悬浮的录音坞。
// 录音坞用 .regularMaterial 悬浮,内容在其下滚动;录音时坞内材质化展开波形 + 状态行。
// 载荷接线保留:录音键 action 仍走既有 controller.toggle();phase(idle/recording/processing/error)照常反映。

struct RecordView: View {
    @EnvironmentObject var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pendingUndo: PendingUndo?
    @State private var editingRecord: DictationRecord?
    @State private var searchQuery = ""
    @State private var exportItem: MarkdownExportItem?
    @StateObject private var playback = AudioPlayback()
    @ScaledMetric(relativeTo: .body) private var feedGap: CGFloat = 6
    // 录音坞计时(纯视觉展示,不驱动任何业务逻辑;真实计时/静音判定仍在 DictationController 内)
    @State private var elapsedSeconds: Int = 0
    private let dockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isRecording: Bool { controller.phase == .recording }
    private var isProcessing: Bool { controller.phase == .processing }
    private var processingLabel: String {
        controller.processingStage == .recognizing ? "正在识别…" : "正在整理成文…"
    }
    private var showDockPanel: Bool { isRecording || isProcessing }
    /// 录音/整理进行中:回放要被拦(避免与录音会话打架)
    private var recordingActive: Bool { isRecording || isProcessing }

    /// 记录若已转码出音频且文件仍在(可能被容量裁剪删掉),给出可播放的绝对路径;否则 nil→不显示播放键。
    private func existingAudioURL(for record: DictationRecord) -> URL? {
        guard let name = record.audioFileName else { return nil }
        let url = controller.history.audioURL(for: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: 全文搜索(内存线性过滤,几千条内足够;逻辑在 core.HistorySearch,带 XCTest)

    private var searchKeywords: [String] { HistorySearch.keywords(from: searchQuery) }
    private var isFiltering: Bool { !searchKeywords.isEmpty }

    /// 匹配范围:整理后文本(finalText ?? cleanText)+ ASR 原文 + 该记录派生的待办文本。
    private var visibleRecords: [DictationRecord] {
        let keywords = searchKeywords
        guard !keywords.isEmpty else { return controller.history.records }
        return controller.history.records.filter { record in
            var fields = [record.finalText ?? record.cleanText, record.rawText]
            fields.append(contentsOf: controller.todos.items
                .filter { $0.sourceRecordID == record.id }
                .map(\.text))
            return HistorySearch.matches(fields: fields, keywords: keywords)
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("记录")
                .background(Theme.bg.ignoresSafeArea())
                .safeAreaInset(edge: .top, spacing: 0) { editModeBanner }
                .safeAreaInset(edge: .top, spacing: 0) {
                    HistoryPersistenceBanner(history: controller.history)
                }
                .safeAreaInset(edge: .bottom) { recordDock }
                .undoBanner($pendingUndo)
                .searchable(text: $searchQuery,
                            placement: .navigationBarDrawer(displayMode: .automatic),
                            prompt: "搜索记事、原文与待办")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button(action: exportMarkdown) {
                                Label(isFiltering ? "导出 Markdown(筛选结果)" : "导出 Markdown",
                                      systemImage: "square.and.arrow.up")
                            }
                            .disabled(visibleRecords.isEmpty && controller.todos.items.isEmpty)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .tint(Theme.accent)
                    }
                }
        }
        .quietInkNavigationChrome()
        .tint(Theme.accent)
        .sheet(item: $exportItem) { item in
            ActivityShareSheet(url: item.url)
        }
        .sheet(item: $editingRecord) { record in
            MemoEditSheet(record: record) { text in
                controller.updateHistoryFinalText(id: record.id, finalText: text)
            }
        }
        .onChange(of: controller.phase) { _, p in
            // 触觉只在因果结果时刻:整理完成 = 成功;失败 = 错误。开始/停止的冲击在录音键 action 里发。
            switch p {
            case .recording: playback.stop()   // 开录前停掉任何回放,避免播放与录音会话打架
            case .done: Haptics.notify(.success)
            case .error: Haptics.notify(.error)
            default: break
            }
        }
    }

    /// 修改模式(语音二次修改-执行方略.md v2 §10 P0)。录音仍走页面底部既有的
    /// `recordDock`/`handleDockTap`,这条 banner 只负责展示"正在改哪条" + 实时听写 +
    /// 结果四态,不新建一套录音 UI。
    @ViewBuilder private var editModeBanner: some View {
        if let target = controller.editingTarget {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack {
                    Label("语音修改", systemImage: "waveform.badge.mic")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Button("取消", action: controller.cancelEdit)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(underlinedTarget(target.baseText))
                    .quietFootnote()
                    .lineLimit(3)
                if controller.phase == .recording || controller.phase == .processing {
                    Text(controller.liveText.isEmpty ? "请说出修改要求…" : controller.liveText)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                } else {
                    Text("点下方录音键说出修改要求")
                        .quietFootnote()
                }
            }
            .padding(Space.md)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Radius.card))
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.xs)
            .background(Theme.bg.opacity(0.92))
        } else if let entry = controller.lastEditOutcome {
            editOutcomeBanner(entry)
        }
    }

    /// 下划线标记"这是正在改的目标"——用实线,与 `MemoRow.attributedText` 标"不确定片段"
    /// 的虚线区分,语义不同不共用样式。
    private func underlinedTarget(_ text: String) -> AttributedString {
        var string = AttributedString(text)
        string.underlineStyle = .single
        return string
    }

    @ViewBuilder
    private func editOutcomeBanner(_ entry: DictationController.EditOutcomeEntry) -> some View {
        let style = editOutcomeStyle(entry.outcome)
        HStack(spacing: Space.sm) {
            Image(systemName: style.icon)
                .foregroundStyle(style.tint)
            Text(style.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if style.showsUndo {
                Button("撤销") {
                    controller.undoLastEdit(recordID: entry.recordID)
                    controller.dismissEditOutcome()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            }
            Button {
                controller.dismissEditOutcome()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Radius.card))
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.xs)
        .background(Theme.bg.opacity(0.92))
        .task(id: entry.id) {
            switch entry.outcome {
            case .noEdit, .unchanged:
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                controller.dismissEditOutcome()
            case .applied, .flaggedLargeChange:
                break   // 保留"撤销"入口,不自动收起
            }
        }
    }

    private func editOutcomeStyle(_ outcome: EditOutcome)
        -> (icon: String, tint: Color, message: String, showsUndo: Bool) {
        switch outcome {
        case .applied:
            return ("checkmark.circle.fill", Theme.ok, "已修改", true)
        case .flaggedLargeChange:
            return ("exclamationmark.triangle.fill", Theme.warn, "改动幅度较大,请确认", true)
        case .noEdit:
            return ("questionmark.circle", Theme.textTertiary, "没听清要改什么,请重说", false)
        case .unchanged:
            return ("minus.circle", Theme.textTertiary, "没有检测到改动", false)
        }
    }

    @ViewBuilder private var content: some View {
        // 空态仅在「没有备忘且当前没在录音」时出现;录音时进 memoList 以便顶部显示实时草稿卡
        if controller.history.records.isEmpty && !showDockPanel {
            emptyState
        } else {
            memoList
        }
    }

    // MARK: 备忘流

    private var memoList: some View {
        List {
            Section {
                // 顶部实时草稿卡:录音/整理中材质化出现,展示 liveText,完成后落定为下方第一条正式备忘卡
                if showDockPanel {
                    LiveDraftCard(text: controller.liveText, isRecording: controller.phase == .recording,
                                  title: controller.editingTarget != nil ? "语音修改内容转写" : "实时转写 · 草稿")
                        .listRowInsets(EdgeInsets(top: feedGap, leading: Space.md, bottom: feedGap, trailing: Space.md))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .transition(reduceMotion ? .opacity : .materialize)
                }
                ForEach(visibleRecords) { record in
                    MemoRow(record: record,
                            audioURL: existingAudioURL(for: record),
                            blocked: recordingActive,
                            playback: playback,
                            prepareForPlayback: controller.prepareForAudioPlayback,
                            onEdit: { editingRecord = record },
                            onVoiceEdit: { controller.beginEdit(recordID: record.id) },
                            onRecognizeWithCloud: {
                                Task { await controller.recognizeWithCloudAgain(record: record) }
                            },
                            recloudInFlight: controller.recloudingRecordID == record.id,
                            onRetryCleanup: { Task { await controller.retryCleanup(record: record) } },
                            cleanupBusy: controller.recleaningRecordID != nil,
                            cleanupMessage: controller.cleanupRetryMessages[record.id])
                        .listRowInsets(EdgeInsets(top: feedGap, leading: Space.md, bottom: feedGap, trailing: Space.md))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onDelete(perform: deleteMemos)
                if isFiltering && visibleRecords.isEmpty {
                    Text("没有匹配的记录")
                        .quietFootnote()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, Space.lg)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            } header: {
                Text(isFiltering ? "匹配 · \(visibleRecords.count)"
                                 : "备忘 · \(controller.history.records.count)")
                    .quietSectionLabel()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { controller.syncHistoryFromCloud() }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.standard,
                   value: controller.history.records.count)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.gentle, value: showDockPanel)
    }

    private var emptyState: some View {
        VStack(spacing: Space.md) {
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("还没有备忘")
                .font(.title3.weight(.semibold))
                .tracking(-0.3)
                .foregroundStyle(Theme.textPrimary)
            Text("轻点下方按钮开始口述,\n整理好的文字会作为备忘留在这里。")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func deleteMemos(_ offsets: IndexSet) {
        let removed = offsets.map { visibleRecords[$0] }
        Haptics.impact(.light)
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.standard) {
            removed.forEach { controller.deleteHistory(id: $0.id) }
        }
        // 宽容撤销:4 秒内可恢复文本(音频若已删不恢复,顺序回到最前)
        pendingUndo = PendingUndo(label: "已删除 \(removed.count) 条备忘") {
            removed.reversed().forEach { controller.history.append($0) }
        }
    }

    // MARK: 导出 Markdown(当前筛选结果 + 全部待办;生成逻辑在 core.MarkdownExport,带 XCTest)

    private func exportMarkdown() {
        let doc = MarkdownExport.document(
            records: visibleRecords.map {
                .init(date: $0.date, text: $0.finalText ?? $0.cleanText, rawText: $0.rawText)
            },
            todos: controller.todos.items.map { .init(text: $0.text, done: $0.done) })
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(MarkdownExport.defaultFileName())
        guard (try? doc.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        Haptics.impact(.light)
        exportItem = MarkdownExportItem(url: url)
    }

    // MARK: 底部录音坞(悬浮材质;待机 = 胶囊 58pt,录音/整理中 = 圆角矩形 26)
    //
    // 规格:.regularMaterial + 0.5pt 描边,左右悬空 20,距 tab bar 16(与系统 tab bar 分离,非贴边通栏)。
    // 载荷接线保留在 handleDockTap() 里,与改版前完全一致:仍走既有 controller.toggle() 流程。

    private var recordDock: some View {
        VStack(spacing: Space.xs + 2) {
            Group {
                if showDockPanel { expandedDock } else { idleDock }
            }
            Text(hintText)
                .quietFootnote()
                .foregroundStyle(hintColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Space.lg)
        }
        .padding(.horizontal, Space.lg - 4)   // 页面左右边距 20
        .padding(.bottom, Space.sm + 6)       // 距 tab bar 16
        .padding(.top, Space.xs)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.gentle, value: showDockPanel)
        .onReceive(dockTimer) { _ in if isRecording { elapsedSeconds += 1 } }
        .onChange(of: isRecording) { _, rec in if rec { elapsedSeconds = 0 } }
    }

    /// 待机态:胶囊,左侧静态波形刻度 +「轻点说话」,右侧 40pt accent 圆键(=开始录音)
    private var idleDock: some View {
        HStack(spacing: Space.md) {
            StaticWaveformTicks()
            Text("轻点说话")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Space.sm)
            RecordButton(isRecording: false, isProcessing: false, action: handleDockTap)
        }
        .padding(.leading, Space.md + 4)
        .padding(.trailing, Space.xs + 2)
        .frame(height: 58)
        .dockMaterial(Capsule())
        .transition(reduceMotion ? .opacity : .materialize)
    }

    /// 录音/整理中:圆角矩形展开,两行——①波形(响度驱动,19 根滚动刻度) ②状态行(红点+文案+计时+停止键)
    private var expandedDock: some View {
        VStack(spacing: Space.sm) {
            LiveWaveformTicks(level: controller.audioLevel)
            HStack(spacing: Space.xs + 2) {
                if isRecording { RecordingDot(diameter: 8, showsGlow: true) }
                Text(isProcessing ? processingLabel : "正在聆听 · 识别中")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isProcessing ? Theme.textSecondary : Theme.danger)
                if isRecording {
                    Text(elapsedLabel)
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: Space.sm)
                RecordButton(isRecording: isRecording, isProcessing: isProcessing, action: handleDockTap)
            }
        }
        .padding(Space.md)
        .dockMaterial(
            RoundedRectangle(cornerRadius: Radius.dockExpanded, style: .continuous),
            tint: isRecording ? Theme.glassTint : nil
        )
        .transition(reduceMotion ? .opacity : .materialize)
    }

    /// ★载荷接线保留:手动点 = standalone;仍调既有 toggle 流程与 phase 反映不变(改版前后逻辑相同)。
    private func handleDockTap() {
        if controller.phase != .recording { controller.mode = .standalone }
        Haptics.impact(controller.phase == .recording ? .rigid : .medium)
        controller.toggle()
    }

    private var elapsedLabel: String {
        let m = elapsedSeconds / 60, s = elapsedSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private var hintText: String {
        switch controller.phase {
        case .idle:
            return "轻点开始口述"
        case .recording:
            // 键盘冷启动即在 App 内正常录音:直接说话,点停止结束——不需要先返回原 App。
            return "说完点停止,或停顿 \(String(format: "%.1f", controller.settings.vadSilenceSeconds)) 秒自动结束"
        case .processing:
            return processingLabel
        case .done:
            if let message = controller.shortcutClipboardMessage { return message }
            if controller.routedToTodo { return "已存入待办 ✓" }
            // 诚实提示:文字已备好,回到刚才的应用、键盘出现时插入(iOS 只把文字放到光标处,故需返回)
            if controller.fromKeyboard { return "文字已就绪,返回刚才的应用即可插入" }
            return "完成,已复制到剪贴板"
        case .error(let msg):
            return msg
        }
    }

    private var hintColor: Color {
        switch controller.phase {
        case .error: return Theme.warn
        case .done where controller.fromKeyboard: return Theme.accent
        default: return Theme.textSecondary
        }
    }
}

// MARK: Markdown 导出的分享载体(系统 share sheet;.md 文件写在 tmp,分享完由系统清理)

private struct MarkdownExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

private struct HistoryPersistenceBanner: View {
    @ObservedObject var history: HistoryStore

    var body: some View {
        if let message = history.persistenceError {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                Text(message).font(.footnote)
                Spacer(minLength: 0)
                Button("重试保存") { history.retryPersistence() }
            }
            .padding(12)
            .background(Color.orange.opacity(0.12))
            .accessibilityElement(children: .contain)
        }
    }
}

// MARK: 顶部实时草稿卡(识别中,材质化出现;完成后落定为正式备忘卡)

struct LiveDraftCard: View {
    let text: String
    /// 只在录音过程中(端侧垫底 + 云端分句逐步替换)带下划线标"未定稿";
    /// 整理阶段(controller.phase == .processing)展示的是 LLM 流式整理结果,不属于这次改造。
    let isRecording: Bool
    /// 卡片抬头文案(2026-08-19 新增):普通口述是"实时转写 · 草稿";修改模式
    /// (`editingTarget != nil`)复用同一张卡片展示"你说的修改要求→模型改完的结果",
    /// 不是在记新笔记,标题改成"语音修改内容转写"避免误导。
    var title: String = "实时转写 · 草稿"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cursorOn = true

    private var draftText: AttributedString {
        var s = AttributedString(text.isEmpty ? "正在聆听…" : text)
        if isRecording, !text.isEmpty {
            s.underlineStyle = Text.LineStyle(pattern: .solid, color: Theme.textSecondary)
        }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                // 草稿卡正文 = Body 17/26(设计稿 2c;此前误用 .callout 16pt)
                Text(draftText)
                    .quietBody()
                    .foregroundStyle(text.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                    .lineLimit(6)
                    .multilineTextAlignment(.leading)
                cursor
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Space.md)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .background(
            // 外圈光晕:accent@7% 模糊光带,叠在描边外(不参与上面的裁切)
            RoundedRectangle(cornerRadius: Radius.card + 4, style: .continuous)
                .fill(Theme.accent.opacity(0.07))
                .blur(radius: 6)
        )
    }

    /// 尾部光标闪烁:2×18pt accent 竖线,示意「正随识别逐字更新」;减弱动态效果时静止常亮。
    private var cursor: some View {
        Rectangle()
            .fill(Theme.accent)
            .frame(width: 2, height: 18)
            .opacity(reduceMotion ? 1 : (cursorOn ? 1 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { cursorOn.toggle() }
            }
    }
}

// MARK: 备忘卡片行(点文字复制 · 有音频则可播原声)

struct MemoRow: View {
    let record: DictationRecord
    let audioURL: URL?
    let blocked: Bool
    @ObservedObject var playback: AudioPlayback
    let prepareForPlayback: () -> Void
    let onEdit: () -> Void
    /// 语音修改(修改模式):进入修改态,由 RecordView 顶部 banner 接管后续录音/结果展示。
    let onVoiceEdit: () -> Void
    /// 离线兜底记录改用云端重识别。非离线记录不会调用。
    let onRecognizeWithCloud: () -> Void
    let recloudInFlight: Bool
    var onRetryCleanup: () -> Void = {}
    var cleanupBusy: Bool = false
    var cleanupMessage: String? = nil
    @State private var copied = false

    private var isOnDeviceFallback: Bool { record.recognitionSource == .onDevice }
    private var recognitionFailed: Bool { record.recognitionError != nil }
    private var hasRecognizedText: Bool {
        !(record.finalText ?? record.cleanText)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 展示稿 + 可疑片段虚线下划线:整理模型改写过 ASR 原文的位置(见 UncertainSpans)。
    /// 用户自己编辑过(finalText 非 nil)之后不再标注——他已经逐字看过一遍,再画虚线只是噪声。
    private var attributedText: AttributedString {
        var string = AttributedString(text)
        guard record.finalText == nil else { return string }
        let spans = UncertainSpans.spans(displayed: text, rawASR: record.rawText)
        guard !spans.isEmpty else { return string }
        let characters = Array(text)
        for span in spans {
            // AttributedString 的下标体系与 Character 数组不通用,按字符距离换算。
            // 越界会直接 trap,所以先挡掉——UncertainSpans 的区间本就落在 text 内,这是保险。
            guard span.range.upperBound < characters.count else { continue }
            let lower = string.index(string.startIndex, offsetByCharacters: span.range.lowerBound)
            let upper = string.index(string.startIndex, offsetByCharacters: span.range.upperBound + 1)
            string[lower..<upper].underlineStyle = Text.LineStyle(
                pattern: .dash, color: Theme.textTertiary)
        }
        return string
    }

    private var text: String {
        let recognized = record.finalText ?? record.cleanText
        return recognized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (audioURL == nil ? "识别失败，原音未能归档" : "识别失败，原音已保存")
            : recognized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            // 文字区独立按钮:点=复制(与播放键分离,避免嵌套按钮抢手势)
            Button {
                UIPasteboard.general.string = text
                Haptics.selection()
                withAnimation(Motion.snappy) { copied = true }
            } label: {
                Text(attributedText)
                    .quietBody()
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.pressable)

            if let summary = record.metrics?.compactSummary {
                Text(summary)
                    .quietFootnote()
            }

            if record.cleanupStatus == .failed {
                HStack {
                    Text("识别完成，整理未完成").font(.caption)
                    Button(cleanupBusy ? "整理中…" : "重新整理", action: onRetryCleanup)
                        .disabled(cleanupBusy || blocked)
                }
            }
            if let cleanupMessage { Text(cleanupMessage).font(.caption).foregroundStyle(Theme.textSecondary) }

            // 离线兜底稿和识别失败记录都可复用已归档原音重试云端 ASR。
            if isOnDeviceFallback || recognitionFailed {
                HStack(spacing: Space.xs) {
                    Label(
                        recognitionFailed ? (audioURL == nil ? "原音归档失败" : "原音已归档") : "离线识别",
                        systemImage: recognitionFailed ? "waveform.badge.exclamationmark" : "wifi.slash")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(recognitionFailed ? Theme.danger : Theme.textTertiary)
                    Button(action: onRecognizeWithCloud) {
                        if recloudInFlight {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text(recognitionFailed ? "重新识别" : "用云端重新识别")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .buttonStyle(.pressable)
                    .disabled(recloudInFlight || audioURL == nil)
                }
            }

            HStack(spacing: Space.xs) {
                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                    .quietFootnote()
                Spacer(minLength: Space.sm)
                if copied {
                    Label("已复制", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.ok)
                        .transition(.opacity)
                } else {
                    // 复制图标 17pt(规格 Screens.1;此前 .caption2 ≈ 11pt 偏小)
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.textTertiary)
                }
                Button(action: onVoiceEdit) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.pressable)
                .disabled(blocked || !hasRecognizedText)
                .accessibilityLabel("语音修改")
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.pressable)
                .disabled(!hasRecognizedText)
                .accessibilityLabel("编辑文字并学习纠错")
                // 有原音才显示播放键(老记录/裁剪掉/云端同步来的无本地音频则不显示)
                if let audioURL {
                    PlayButton(url: audioURL, id: record.id, blocked: blocked,
                               playback: playback, prepareForPlayback: prepareForPlayback)
                }
            }
        }
        .padding(.top, Space.md)
        .padding(.horizontal, Space.md)
        .padding(.bottom, Space.sm + 2)   // 卡片内边距:16(底 12)
        .cardSurface()
        .contextMenu {
            // 与导出复用同一 core.MarkdownExport 生成函数,双端行为一致
            Button {
                UIPasteboard.general.string = MarkdownExport.recordMarkdown(
                    .init(date: record.date, text: text, rawText: record.rawText))
                Haptics.selection()
            } label: {
                Label("复制为 Markdown", systemImage: "doc.on.doc")
            }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(Motion.standard) { copied = false }
        }
    }
}

/// 历史文字的最小编辑闭环：保存后记录 finalText，并由
/// DictionaryMiner 提取带上下文的精确纠错对。
private struct MemoEditSheet: View {
    let record: DictationRecord
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(record: DictationRecord, onSave: @escaping (String) -> Void) {
        self.record = record
        self.onSave = onSave
        _draft = State(initialValue: record.finalText ?? record.cleanText)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("修正后，Shall We Talk 会记住这一处带上下文的识别纠错。")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                TextEditor(text: $draft)
                    .quietBody()
                    .padding(Space.sm)
                    .scrollContentBackground(.hidden)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Radius.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.card)
                            .strokeBorder(Theme.border, lineWidth: 0.5)
                    )
            }
            .padding(Space.md)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("编辑识别文字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(draft.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .quietInkNavigationChrome()
    }
}

// MARK: 原音播放键(小图标、≥44pt 命中区;播放时显进度环并可再点停止)

struct PlayButton: View {
    let url: URL
    let id: UUID
    let blocked: Bool
    @ObservedObject var playback: AudioPlayback
    let prepareForPlayback: () -> Void

    var body: some View {
        let playing = playback.isPlaying(id)
        Button {
            if !playing && !blocked { prepareForPlayback() }
            playback.toggle(url: url, id: id, blocked: blocked)
        } label: {
            ZStack {
                // 规格:28pt 圆,1.5pt accent@45% 描边;播放中叠加进度环
                Circle().strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1.5)
                    .frame(width: 28, height: 28)
                if playing {
                    Circle().trim(from: 0, to: max(0.001, playback.progress))
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 28, height: 28)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                } else {
                    // accent 实心三角 9pt
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.accent)
                        .offset(x: 1)   // 三角视觉居中微调
                }
            }
            .frame(width: 44, height: 44)          // ≥44pt 命中区
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(playing ? "停止播放" : "播放原声")
    }
}

// MARK: - 全局录音悬浮条(非记录页兜底:任何 tab 录音进行中都有一个清晰指示 + 停止)

/// 单一全局指示,挂在 RootView 的 TabView 之上;记录页由录音坞承担、这里被抑制(不叠加)。
/// 复用既有 RecordingDot / Theme / Motion / PressableStyle / Haptics,保持 DRY;停止走既有 controller.toggle()。
/// 胶囊主体(除停止钮外)点按 = 切回记录 tab;由 RootView 通过 `.environment(\.selectRecordTab, ...)`
/// 注入,`GlobalRecordingBar()` 本身保持零参调用(停止钮是内部独立 Button,行为不受影响)。
private struct SelectRecordTabKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}
extension EnvironmentValues {
    var selectRecordTab: () -> Void {
        get { self[SelectRecordTabKey.self] }
        set { self[SelectRecordTabKey.self] = newValue }
    }
}

struct GlobalRecordingBar: View {
    @EnvironmentObject var controller: DictationController
    @Environment(\.selectRecordTab) private var selectRecordTab
    // 跨页胶囊计时(纯视觉展示;真实计时/静音判定仍在 DictationController 内)
    @State private var elapsedSeconds: Int = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isRecording: Bool { controller.phase == .recording }
    private var isProcessing: Bool { controller.phase == .processing }
    private var processingLabel: String {
        controller.processingStage == .recognizing ? "正在识别…" : "正在整理成文…"
    }

    var body: some View {
        HStack(spacing: Space.xs + 2) {
            if isRecording {
                RecordingDot(diameter: 7)
            } else {
                ProgressView().scaleEffect(0.6).tint(Theme.textSecondary)
            }
            Text(isProcessing ? processingLabel : "正在录音")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isProcessing ? Theme.textSecondary : Theme.danger)
            if isRecording {
                WaveformBars(level: controller.audioLevel, barWidth: 2.5, maxHeight: 14, spacing: 2.5)
                Text(elapsedLabel)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            if isRecording {
                // 停止:走既有 toggle→finish 流程(捕捉模式下文字仍照常入待办)
                Button {
                    Haptics.impact(.rigid)
                    controller.toggle()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Theme.dangerGradient, in: Circle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("停止")
            }
        }
        .padding(.horizontal, Space.md)
        .frame(height: 40)
        .dockMaterial(Capsule(), tint: isRecording ? Theme.glassTint : nil)
        .contentShape(Capsule())
        .onTapGesture { selectRecordTab() }   // 停止钮是独立 Button,命中其区域时优先响应,不会触发这里
        .padding(.horizontal, Space.lg)
        .onReceive(timer) { _ in if isRecording { elapsedSeconds += 1 } }
        .onChange(of: isRecording) { _, rec in if rec { elapsedSeconds = 0 } }
    }

    private var elapsedLabel: String {
        let m = elapsedSeconds / 60, s = elapsedSeconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - 页 2「待办」(闪念胶囊)

struct TodosTab: View {
    @EnvironmentObject var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pendingUndo: PendingUndo?
    @StateObject private var playback = AudioPlayback()
    @State private var refiningIDs: Set<UUID> = []
    @State private var refineErrors: [UUID: String] = [:]
    @State private var draggingTodoID: UUID?
    /// 操作按钮用法提示是否已被关掉。老用户不需要它一直挂在列表末尾。
    /// 直接声明在 View 里(不进 `MobileSettingsStore`):这样写入即触发重渲染,
    /// 不会踩 §11.2 那个"@AppStorage 放在 ObservableObject 里不发 objectWillChange"的坑。
    @AppStorage("todoActionButtonHintDismissed") private var actionHintDismissed = false
    /// 系统「实时活动」总开关。关着时操作按钮录音全程没有灵动岛,而且后台开麦可能
    /// 直接失败(§11.1a)。这条警告**不受 `actionHintDismissed` 约束**:它不是用法提示,
    /// 是功能已被系统关掉的事实。
    @State private var liveActivitiesEnabled = true

    var body: some View {
        NavigationStack {
            Group {
                if controller.todos.items.isEmpty {
                    emptyState
                } else {
                    todoList
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .safeAreaInset(edge: .top) {
                if let error = controller.todos.persistenceError {
                    HStack {
                        Text(error).font(.caption)
                        Button("重试保存") { controller.todos.retryPersistence() }
                    }.padding().background(Theme.bg)
                }
            }
            .navigationTitle("待办")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        controller.mode = .todoCapture   // 待办页是明确意图，不依赖口述触发词
                        Haptics.impact(.medium)
                        controller.toggle()
                    } label: {
                        Image(systemName: "mic.badge.plus").font(.body.weight(.semibold))
                    }
                    .tint(Theme.accent)
                    // 录音/整理进行中禁用:停止的唯一入口是全局悬浮条(GlobalRecordingBar),
                    // 避免这里再造一个可同时点到的"隐形停止键"——两个控件都能触发 toggle() 本身虽安全
                    // (finish() 有幂等闸门),但这枚按钮每次点按时都会重设 mode=.todoCapture,
                    // 双控件并存容易在排查时误导;禁用后「非记录页恰好一个可操作的停止控件」这条不变式
                    // 由 UI 直接保证,不必依赖时序巧合。
                    .disabled(controller.phase == .recording || controller.phase == .processing)
                }
            }
            .undoBanner($pendingUndo)
        }
        .quietInkNavigationChrome()
        .tint(Theme.accent)
        .onAppear { liveActivitiesEnabled = CaptureLiveActivityController.areActivitiesEnabled }
        // 用户是切到系统设置里改这个开关的,回到前台必须复查,否则会一直显示过期的警告。
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification
        )) { _ in
            liveActivitiesEnabled = CaptureLiveActivityController.areActivitiesEnabled
        }
    }

    /// 实时活动被系统关掉时的警告。不是"用法提示",所以不受关闭按钮约束——
    /// 它说的是"这个功能现在是坏的",而且用户按操作按钮时除了灵动岛没有任何其它反馈渠道。
    @ViewBuilder
    private var liveActivityDisabledWarning: some View {
        if !liveActivitiesEnabled {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text("系统「实时活动」已关闭：用操作按钮口述时，灵动岛不会显示录音状态，"
                         + "后台起录也可能失败。")
                        .quietFootnote()
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("打开设置 → 实时活动", destination: url)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.leading, 21)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.md) {
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("闪念待办")
                .font(.title3.weight(.semibold))
                .tracking(-0.3)
                .foregroundStyle(Theme.textPrimary)
            Text("键盘口述以「提醒我 / 记一下」开头会自动收进这里;\n右上角的麦克风也能随时口述一条。")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if !actionHintDismissed {
                Text(Self.actionButtonHintText)
                    .quietFootnote()
                    .multilineTextAlignment(.center)
                    .padding(.top, Space.sm)
            }
            liveActivityDisabledWarning
                .padding(.top, Space.sm)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 操作按钮(Action Button)入口说明。空态与列表末尾共用同一句:空态负责首次发现,
    /// 列表末尾负责"已经在用、但还不知道有这条捷径"的老用户——滑到底才看到,不占视线。
    /// 「语音待办」是 `StartTodoCaptureIntent.title`,改那里的标题时这句也要跟着改。
    /// 2026-09-14 起两条入口分工不同:操作按钮(`StartTodoCaptureIntent`,标题「语音待办」)
    /// 一律强制建待办;「语音输入」(`StartNoteCaptureIntent`)只在命中触发词时才建待办,
    /// 可绑到轻点背面等场景。
    /// ⚠️「长按」不是我们的交互设计,是操作按钮的硬件行为:iPhone 的操作按钮只认长按
    /// (短按不响应,防误触),所以两次触发都得长按。代码侧 `perform()` 每次触发只做一次
    /// 状态翻转(第一次起录、第二次发停止请求),与按法无关,两个 Intent 都一样。
    private static let actionButtonHintText =
        "全局「语音待办」（操作按钮）会一律加入待办，并把整理稿保存到「记录」；"
        + "正在使用 Shall We Talk 键盘时会自动插入，否则可从剪贴板粘贴。"
        + "只想记录、不想强制建待办？可在系统设置里把「语音输入」这条捷径绑到轻点背面等操作——"
        + "它只有以「提醒我 / 记一下 / 待办」等触发词开头时才会额外进入待办。"
        + "如从多任务界面上划关闭 App，请先重新打开 Shall We Talk 一次，以恢复操作按钮的后台录音。"

    /// 列表末尾版:左对齐 + 图标,与上方待办卡片的左缘对齐。空态那份是居中纯文字,
    /// 居中布局里放带前导图标的 HStack 会视觉偏移,故不共用同一个视图。
    /// 关闭按钮只挂在这一版:空态本身就是"还没有待办"的引导场景,不该有关闭动作;
    /// 但它同样受 `actionHintDismissed` 约束——在这里关掉,空态也不会再出现。
    private var actionButtonHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "button.horizontal.top.press")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(Self.actionButtonHintText)
                .quietFootnote()
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Haptics.impact(.light)
                withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.standard) {
                    actionHintDismissed = true
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 28, height: 28)   // 图标 11pt 太小点不中,撑出可点区域
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("不再显示操作按钮用法")
        }
    }

    // ScrollView + LazyVStack(替代 List)以支持自定义左右滑手势 + 长按拖动视觉;
    // 保留:跨页录音胶囊(挂在 RootView 更上层,不受影响)、待办 badge、进入录音的 toolbar 入口、拖动重排。
    private var todoList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("待办 · \(controller.todos.pendingCount)")
                    .quietSectionLabel()
                    .padding(.top, 4)
                ForEach(controller.todos.pending) { item in
                    todoCard(item)
                }

                if !controller.todos.completed.isEmpty {
                    Text("已完成 · \(controller.todos.completed.count)")
                        .quietSectionLabel()
                        .padding(.top, 8)
                    ForEach(controller.todos.completed) { item in
                        todoCard(item)
                    }
                    Button(role: .destructive) {
                        Haptics.impact(.light)
                        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.standard) {
                            controller.todos.clearCompleted()
                        }
                    } label: {
                        Label("清除已完成", systemImage: "trash")
                            .font(.subheadline)
                    }
                    .padding(.top, 2)
                }

                liveActivityDisabledWarning
                    .padding(.top, Space.lg)

                if !actionHintDismissed {
                    actionButtonHint
                        .padding(.top, liveActivitiesEnabled ? Space.lg : Space.sm)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, Space.lg - 4)   // 页面左右边距 20
            .padding(.bottom, 120)                // 给底部跨页录音胶囊/tab bar 留空间
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.standard, value: controller.todos.items)
    }

    private func todoCard(_ item: TodoItem) -> some View {
        let audioURL = item.sourceRecordID.flatMap { controller.history.audioURL(forRecordID: $0) }
        return TodoCard(
            item: item,
            audioURL: audioURL,
            playback: playback,
            prepareForPlayback: controller.prepareForAudioPlayback,
            audioBlocked: controller.phase == .recording || controller.phase == .processing,
            isRefining: refiningIDs.contains(item.id),
            refineError: refineErrors[item.id],
            isBeingDragged: draggingTodoID == item.id,
            onSaveText: { controller.updateTodoText(item.id, text: $0) },
            onToggleDone: {
                Haptics.impact(.light)
                withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.standard) {
                    controller.todos.toggle(item.id)
                }
            },
            onDelete: { deleteTodo(item) },
            onRefine: { refine(item) }
        )
        // 行身份纳入 done:LazyVStack 的懒行缓存按身份复用子树,done 翻转(完成/恢复移区)时
        // 强制重建,删除线与降对比即时正确;顺带把滑动 offset 等 @State 一起归零。
        // 同区拖动重排 done 不变 → 身份不变,重排动画不受影响。
        .id("\(item.id.uuidString)-\(item.done ? 1 : 0)")
        .onDrag {
            draggingTodoID = item.id
            return NSItemProvider(object: item.id.uuidString as NSString)
        }
        .onDrop(of: [UTType.text], delegate: TodoReorderDropDelegate(
            targetID: item.id,
            draggingID: $draggingTodoID,
            move: { sourceID, targetID in
                withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.standard) {
                    controller.todos.move(sourceID, before: targetID)
                }
            }
        ))
    }

    private func refine(_ item: TodoItem) {
        guard !refiningIDs.contains(item.id) else { return }
        refiningIDs.insert(item.id)
        refineErrors[item.id] = nil
        Task {
            do { try await controller.refineTodo(item) }
            catch { refineErrors[item.id] = error.localizedDescription }
            refiningIDs.remove(item.id)
        }
    }

    private func deleteTodo(_ item: TodoItem) {
        Haptics.impact(.light)
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.standard) {
            controller.todos.delete(item.id)
        }
        pendingUndo = PendingUndo(label: "已删除待办") {
            controller.todos.restore(item)
        }
    }
}

private struct TodoReorderDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var draggingID: UUID?
    let move: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let sourceID = draggingID, sourceID != targetID else { return }
        move(sourceID, targetID)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

// MARK: - 设置页视觉组件(规格 §Screens.4 + 截图 2e:主页 = 分组行(icon tile + 标题 + detail 摘要 +
// chevron)点入子页;子页沿用 Quiet Ink 卡片风格承载原有控件,不增删功能)

struct SettingsIconTile: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.accent)
            .frame(width: 30, height: 30)
            .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.iconTile, style: .continuous))
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Theme.separator).frame(height: 0.5)
    }
}

struct SettingsCard<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SettingsIconTile(systemName: icon)
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }
            SettingsDivider()
            VStack(alignment: .leading, spacing: 14) { content }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 0.5)
        )
    }
}

struct SettingsNavRow: View {
    let title: String
    var body: some View {
        HStack {
            Text(title).font(.system(size: 17)).foregroundStyle(Theme.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.inkAdaptive(lightOpacity: 0.28, darkOpacity: 0.3))
        }
    }
}

/// 主设置页分组行(截图 2e):icon tile 30pt + 标题 17pt + detail 摘要 15pt inkSecondary + chevron ink@28%,行高 52。
struct SettingsGroupRow: View {
    let icon: String
    let title: String
    var detail: String = ""
    var body: some View {
        HStack(spacing: 12) {
            SettingsIconTile(systemName: icon)
            Text(title).font(.system(size: 17)).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: Space.sm)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.inkAdaptive(lightOpacity: 0.28, darkOpacity: 0.3))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

/// 主设置页分组卡:多行分组行叠 0.5pt 分隔线(左缩进对齐文字起点),card 圆角 22。
struct SettingsGroupCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.vertical, 2)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 0.5)
            )
    }
}

struct SettingsRowDivider: View {
    var body: some View {
        Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 58)
    }
}

/// 子页容器:Quiet Ink 画布底 + 滚动卡片区,承载原有控件。
struct SettingsDetailPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(spacing: 14) { content }
                .padding(.horizontal, Space.lg - 4)
                .padding(.vertical, Space.md)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
    }
}

// MARK: - 页 3「设置」(重组:常用在前,进阶更深)

struct SettingsTab: View {
    @EnvironmentObject var controller: DictationController
    @EnvironmentObject var meetingController: MeetingRecordingController

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // 外观:跟随系统 / 浅色 / 深色——单独一行,内联分段选择(一步可达,不值得一个子页)
                    SettingsCard(icon: "circle.lefthalf.filled", title: "外观") {
                        Picker("外观", selection: controller.settings.$appearanceModeRaw) {
                            ForEach(AppearanceMode.allCases) { m in Text(m.rawValue).tag(m.rawValue) }
                        }
                        .pickerStyle(.segmented)
                    }

                    // 分组卡 1:录音与整理 / 同步与备份 / 识别与模型(点入子页;detail 取真实状态)
                    SettingsGroupCard {
                        NavigationLink { RecordingSettingsPage() } label: {
                            SettingsGroupRow(icon: "waveform", title: "录音与整理", detail: recordingDetail)
                        }
                        .buttonStyle(.plain)
                        SettingsRowDivider()
                        NavigationLink { SyncSettingsPage() } label: {
                            SettingsGroupRow(icon: "icloud", title: "同步与备份",
                                             detail: controller.settings.iCloudSyncEnabled ? "iCloud 已开启" : "未开启")
                        }
                        .buttonStyle(.plain)
                        SettingsRowDivider()
                        NavigationLink { ModelSettingsPage() } label: {
                            SettingsGroupRow(icon: "network", title: "连接设置",
                                             detail: controller.settings.networkRoute.title)
                        }
                        .buttonStyle(.plain)
                        SettingsRowDivider()
                        NavigationLink { MeetingSettingsPage() } label: {
                            SettingsGroupRow(icon: "person.wave.2", title: "会议记录",
                                             detail: meetingSettingsDetail)
                        }
                        .buttonStyle(.plain)
                    }

                    // 简繁切换独立于录音与整理，避免把识别输出字形误认为整理力度的一部分。
                    SettingsGroupCard {
                        NavigationLink { LanguageVariantSettingsPage() } label: {
                            SettingsGroupRow(icon: "character", title: "简繁切换", detail: languageVariantDetail)
                        }
                        .buttonStyle(.plain)
                    }

                    // 分组卡 2:词典 / 键盘 / 诊断
                    SettingsGroupCard {
                        NavigationLink { DictionarySettingsPage() } label: {
                            SettingsGroupRow(icon: "character.book.closed", title: "词典",
                                             detail: "\(controller.settings.dictionaryWords.count) 个词条")
                        }
                        .buttonStyle(.plain)
                        SettingsRowDivider()
                        NavigationLink { KeyboardSettingsPage() } label: {
                            SettingsGroupRow(icon: "keyboard", title: "键盘")
                        }
                        .buttonStyle(.plain)
                        SettingsRowDivider()
                        NavigationLink { DiagnosticsSettingsPage() } label: {
                            SettingsGroupRow(icon: "waveform.path.ecg", title: "诊断")
                        }
                        .buttonStyle(.plain)
                    }

                    Text(versionLabel)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.inkAdaptive(lightOpacity: 0.35, darkOpacity: 0.4))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                }
                .padding(.horizontal, Space.lg - 4)   // 页面左右边距 20
                .padding(.vertical, Space.md)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("设置")
            .tint(Theme.accent)
        }
        .quietInkNavigationChrome()
    }

    /// 主页 detail 摘要:整理力度(轻/重)+ 是否自动停
    private var recordingDetail: String {
        let level = CleanupLevel(rawValue: controller.settings.cleanupLevelRaw) ?? .heavy
        return controller.settings.vadEnabled ? "自动停 · 力度\(level.rawValue)" : "力度\(level.rawValue)"
    }

    private var meetingSettingsDetail: String {
        controller.settings.meetingSpeakerDiarization ? "说话人分离开" : "说话人分离关"
    }

    private var languageVariantDetail: String {
        controller.settings.outputTraditionalChinese ? "繁体(香港)" : "简体"
    }

    private var versionLabel: String {
        let name = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "App"
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "\(name) \(v) (\(b))"
    }
}

// MARK: - 设置子页(六区;控件从原单页原样搬入,不增删功能)

private struct RecordingSettingsPage: View {
    @EnvironmentObject var controller: DictationController
    // ⚠️ 本页新增 Picker / 条件子视图时:`@AppStorage` 放在 `MobileSettingsStore` 里写入生效
    // 但**不发 objectWillChange**,只观察 controller 的这一页不会重渲染,表现是"点了没反应、
    // 选不动"。解法是在 View 层用**同 key** 再声明一次 `@AppStorage`。build 33「画中画方式」、
    // build 73「冷启动自动返回」各踩过一次,详见 §11.2。
    // 整理力度的说明文案要随选中档位切换,正是上面这个坑的适用场景:Picker 直接绑这一份,
    // 读写都走 View 层,`controller.settings.cleanupLevel` 读的是同一个 UserDefaults 键。
    @AppStorage("cleanupLevel") private var cleanupLevelRaw = CleanupLevel.heavy.rawValue
    /// 同上:待命开关读偏好,必须在 View 层用同 key 再声明一次才会随写入重渲染。
    /// 默认值必须与 `MobileSettingsStore.standbyPreferredOn` 保持一致(true),否则装机
    /// 首次进设置会看到开关是关的、而实际待命已经建起来了。
    @AppStorage("standbyPreferredOn") private var standbyPreferredOn = true
    /// 待命机制偏好(iOS 27 起可选)。键名与 `StandbyController.preferenceKey` 必须一致。
    @AppStorage(StandbyController.preferenceKey) private var standbyMechanism = StandbyController.Kind.auto.rawValue

    private var cleanupLevelNote: String {
        switch CleanupLevel(rawValue: cleanupLevelRaw) ?? .heavy {
        case .light:
            return "轻:始终使用短口述整理，修正识别错误并基础润色，不分段编号。"
        case .heavy:
            return "重:用整理模型重新跑一遍,按需分段,并列的意思或事项加上序号。"
        }
    }

    var body: some View {
        SettingsDetailPage(title: "录音与整理") {
            SettingsCard(icon: "button.horizontal.top.press", title: "全局语音入口") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("操作按钮", systemImage: "iphone.gen3")
                        .font(.system(size: 14, weight: .semibold))
                    Text("设置 → 操作按钮 → 快捷指令 → Shall We Talk「语音待办」。"
                         + "长按开始，再长按一次结束。一律加入待办，并保存到记录。"
                         + "当前是 Shall We Talk 键盘时，结果会自动插入当前输入框；"
                         + "其他键盘下则保留在剪贴板。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text("使用前提：Shall We Talk 必须处于可后台唤醒状态。"
                             + "正常返回后台或被系统回收不等于强制退出；"
                             + "若从多任务界面上划关闭 App，iOS 会阻止操作按钮在后台重新启动它，"
                             + "请先手动打开 Shall We Talk 一次。"
                             + "无需保持 App 前台，也不要求开启画中画待命。")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Divider()
                    Label("背面轻点三下", systemImage: "hand.tap")
                        .font(.system(size: 14, weight: .semibold))
                    Text("先在「快捷指令」App 新建一条快捷指令，加入 Shall We Talk「语音输入」动作;"
                         + "再到 设置 → 辅助功能 → 触控 → 轻点背面 → 轻点三下，选择该快捷指令。"
                         + "两个入口共用相同的录音、识别、键盘插入/复制流程，"
                         + "区别只在是否强制建待办：「语音待办」一律加入待办，"
                         + "「语音输入」只有命中「提醒我」等触发词才会额外加入待办。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            SettingsCard(icon: "mic.badge.plus", title: "免切换待命") {
                // 开关读的是**偏好**而不是运行时的 `standbyEnabled`:偏好装机即开、只有刻意
                // 关掉才关,而运行时状态会因为会话到期/来电中断/进程回收变 false——用后者驱动
                // 开关的话,用户会看到自己没碰过的开关自己弹回关闭。下方 `standbyStatus`
                // 那一行显示的才是此刻的真实状态,两者分工不同。
                // 2026-09-08:此处曾有一条 SCK 专属的「一键开始授权与待命」按钮分支
                // (它每次新会话都要弹系统共享面板)。SCK 删除后没有任何机制需要授权面板,
                // 分支随之移除,只剩这一个开关。
                Toggle("保持键盘随时可以录音", isOn: Binding(
                    get: { standbyPreferredOn },
                    set: { controller.setStandbyEnabled($0) }
                ))
                .tint(Theme.accent)
                .disabled(controller.standbyIsStarting)
                // 待命机制二选一。**「自动」恒为画中画,默认不变**;「麦克风」是
                // 2026-09-08 新增的纯音频待命(零非公开接口,代价是橙点常亮),只能显式选。
                // 原先的第三项 ScreenCaptureKit 已于同日按用户决定删除。
                // 2026-09-08:屏幕捕获(iOS 27 专有)删除后，两个选项在所有支持的系统上
                // 都可用，选择器不再需要版本门限。
                do {
                    Picker("待命机制", selection: Binding(
                        get: { standbyMechanism },
                        set: { standbyMechanism = $0 }
                    )) {
                        Text("自动").tag(StandbyController.Kind.auto.rawValue)
                        Text("画中画").tag(StandbyController.Kind.pictureInPicture.rawValue)
                        Text("麦克风").tag(StandbyController.Kind.audioSession.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: standbyMechanism) { _, _ in
                        controller.standbyMechanismPreferenceDidChange()
                    }
                    Text("「自动」仍是画中画，默认不变。「麦克风」全程只用公开 API"
                         + "(AVAudioSession + audio 后台模式)，不需要画中画的私有样式调用，"
                         + "代价是待命期间系统橙色麦克风指示点常亮、其它 App 音频被压低。"
                         + "切换机制会先停止旧会话。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                // 2026-08-03:「即时待命 / 画中画省电」二选一改为单一方案,选择器整条删除。
                // 说明块随之常驻显示,不再依赖选中项。
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "rectangle.compress.vertical")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text(StandbyController.mechanismExplanation)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("画中画无痕待命说明")
                Toggle("口述后自动返回原 App", isOn: controller.settings.$coldReturnEnabled)
                    .tint(Theme.accent)
                Text(controller.settings.coldReturnEnabled
                     ? "从键盘启动录音后，识别当前 App 并尝试自动返回。无法确认目标时会留在 Shall We Talk。"
                     : "已关闭：启动录音后请自行返回原 App。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("待命时长", selection: controller.settings.$standbyDurationRaw) {
                    ForEach(StandbyDuration.allCases) { duration in
                        Text(duration.rawValue).tag(duration.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: controller.settings.standbyDurationRaw) {
                    controller.restartStandbyWithSelectedDuration()
                }
                Text(controller.standbyIsStarting ? "正在启动待命方式…" : controller.standbyStatus)
                    .font(.system(size: 13))
                    .foregroundStyle(controller.standbyEnabled ? Theme.accent : Theme.textSecondary)
                Text(StandbyController.mechanismFooter)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            SettingsCard(icon: "waveform", title: "录音与整理") {
                Toggle("停顿后自动结束录音", isOn: controller.settings.$vadEnabled)
                    .tint(Theme.accent)
                if controller.settings.vadEnabled {
                    Picker("静音阈值", selection: controller.settings.$vadSilenceSeconds) {
                        Text("1.5 秒").tag(1.5)
                        Text("2.5 秒").tag(2.5)
                        Text("4 秒").tag(4.0)
                    }
                    .pickerStyle(.segmented)
                }
                Picker("整理力度", selection: $cleanupLevelRaw) {
                    ForEach(CleanupLevel.allCases) { l in Text(l.rawValue).tag(l.rawValue) }
                }
                .pickerStyle(.segmented)
                Text(cleanupLevelNote)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Text("两档都不会书面化、总结或改写你的用词,也只对达到下方阈值的长口述生效。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                Stepper(
                    "完整整理阈值：\(Int(controller.settings.fullCleanupThresholdSeconds)) 秒",
                    value: controller.settings.$fullCleanupThresholdSeconds,
                    in: DictationPolicy.fullCleanupThresholdRange,
                    step: 1
                )
                Text("两档都会改写成通顺文字；短于阈值不分段编号，达到阈值后才按需分段并给并列枚举加序号。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                TextField("自定义整理指令(可留空)", text: controller.settings.$customPrompt, axis: .vertical)
                    .lineLimit(2...5)
                    .font(.system(size: 15))
                Text("已输入 \(controller.settings.customPrompt.count) 字；仅前 500 字用于整理。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

private struct LanguageVariantSettingsPage: View {
    /// 使用与 MobileSettingsStore 相同的 key，让 Picker 的选择立即驱动页面和识别配置更新。
    @AppStorage("outputTraditionalChinese") private var outputTraditionalChinese = false

    var body: some View {
        SettingsDetailPage(title: "简繁切换") {
            SettingsCard(icon: "character", title: "识别输出字形") {
                Picker("简繁切换", selection: $outputTraditionalChinese) {
                    Text("简体").tag(false)
                    Text("繁体(香港)").tag(true)
                }
                .pickerStyle(.segmented)
                Text("语音识别会直接输出所选字形；文字整理会保留原有简繁，不进行简繁转换。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

private struct SyncSettingsPage: View {
    @EnvironmentObject var controller: DictationController
    var body: some View {
        SettingsDetailPage(title: "同步与备份") {
            SettingsCard(icon: "icloud", title: "同步与备份") {
                Toggle("跨设备同步口述历史(仅文本)", isOn: controller.settings.$iCloudSyncEnabled)
                    .tint(Theme.accent)
                    .onChange(of: controller.settings.iCloudSyncEnabled) { _, enabled in
                        if enabled {
                            controller.syncHistoryToCloud()
                            controller.syncHistoryFromCloud()
                        }
                    }
                Text(controller.lastCloudSyncStatus)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                HStack {
                    Button("从 iCloud 拉取") { controller.syncHistoryFromCloud() }
                    Spacer()
                    Button("上传本地历史") { controller.syncHistoryToCloud() }
                }
                .font(.system(size: 14))
                .disabled(!controller.settings.iCloudSyncEnabled)
                Text(CloudHistorySync.isAvailable
                     ? "iCloud 可用;仅同步文本历史,音频不会上传。"
                     : "iCloud 不可用:请登录 iCloud 并确认工程已开启 iCloud Documents 能力。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            SettingsCard(icon: "character.book.closed", title: "词典与纠错跨设备同步") {
                Toggle("跨设备同步个人词典与纠错对", isOn: controller.settings.$dictionarySyncEnabled)
                    .tint(Theme.accent)
                    .onChange(of: controller.settings.dictionarySyncEnabled) { _, enabled in
                        if enabled { controller.scheduleDictionarySync(reason: "开启同步") } else { controller.cancelDictionarySync() }
                    }
                Text(controller.lastDictionarySyncStatus)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Text("与 iOS(含键盘热词)上确认的加词/修改在 macOS 同样生效,反之亦然;删除会同步为墓碑,不会被旧设备重新加回。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

private struct ModelSettingsPage: View {
    @EnvironmentObject var controller: DictationController
    @State private var connectionStatus = ""
    /// 与 MobileSettingsStore 使用同一 key，保证切换线路后本页立即刷新并显示对应 token。
    @AppStorage("networkRoute") private var networkRouteRaw = MobileSettingsStore.defaultNetworkRoute

    private var networkRoute: MobileNetworkRoute {
        MobileNetworkRoute(rawValue: networkRouteRaw) ?? .direct
    }

    var body: some View {
        SettingsDetailPage(title: "连接设置") {
            SettingsCard(icon: "network", title: "网络连接") {
                Picker("连接线路", selection: $networkRouteRaw) {
                    ForEach(MobileNetworkRoute.allCases) { route in
                        Text(route.title).tag(route.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text("选择适合当前网络的连接方式。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                if !connectionStatus.isEmpty {
                    Text(connectionStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .task(id: networkRouteRaw) {
            guard networkRoute.usesWorker else { connectionStatus = ""; return }
            connectionStatus = "正在检查连接…"
            let selected = networkRouteRaw
            do {
                try await controller.settings.prepareRelaySession()
                guard !Task.isCancelled, selected == networkRouteRaw else { return }
                guard let base = URL(string: controller.settings.activeWorkerBaseURLString),
                      base.scheme == "https", base.host != nil else {
                    connectionStatus = "当前线路配置无效，请联系服务提供方。"
                    return
                }
                var request = URLRequest(url: base.appendingPathComponent("warmup"))
                request.httpMethod = "HEAD"
                request.timeoutInterval = 8
                request.setValue("Bearer " + controller.settings.activeWorkerToken, forHTTPHeaderField: "Authorization")
                let (_, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled, selected == networkRouteRaw else { return }
                connectionStatus = (response as? HTTPURLResponse)?.statusCode == 204
                    ? "连接与授权正常" : "当前线路不可用，请选择其他连接方式。"
            } catch {
                guard !Task.isCancelled, selected == networkRouteRaw else { return }
                connectionStatus = "当前线路不可用，请选择其他连接方式。"
            }
        }
    }
}

private struct DictionarySettingsPage: View {
    @EnvironmentObject var controller: DictationController
    @State private var newWord = ""
    @State private var editingWord: String?
    @State private var editingDraft = ""
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var exportDocument = DictionaryJSONDocument(backup: DictionaryBackup())
    @State private var pendingImport: DictionaryBackup?
    @State private var importPreview = ""
    @State private var showImportPreview = false
    @State private var importMessage = ""
    @State private var showImportMessage = false
    @State private var correctionSource = ""
    @State private var correctionTarget = ""
    /// 正在编辑的纠错对,按原 source 定位(编辑态下这个值不跟着输入框变,只用来找到
    /// 是哪一张卡片、以及保存时判断 source 有没有被改名);非 nil 时该卡片切到编辑态。
    @State private var editingCorrectionSource: String?
    @State private var editingCorrectionSourceDraft = ""
    @State private var editingCorrectionDraft = ""
    /// 热词卡片两列对称布局(2026-08-19 改)。纠错对内容更宽(词组+箭头+词组),
    /// 仍保持单列,不在此列之列。
    private let dictionaryColumns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    /// 手动添加 ∪ 本机学习 ∪ 跨设备同步的纠错对合并结果(见
    /// DictionarySyncCoordinator.effectiveCorrections)。2026-08-19 起词典页不再区分
    /// "替换词组"(手动)与"已学到的纠错对"(自动)两个概念——对用户来说都是同一件事,
    /// 统一叫"纠错对",统一可编辑可删除;差异只在幕后的合并优先级(手动 > 本机学习 > 同步)。
    private var allCorrections: [LearnedCorrection] {
        DictionarySyncCoordinator.effectiveCorrections(
            records: controller.history.records, manual: controller.settings.manualCorrections,
            blocked: controller.settings.blockedCorrectionSources)
    }

    var body: some View {
        SettingsDetailPage(title: "词典") {
            SettingsCard(icon: "icloud", title: "同步状态") {
                HStack {
                    if controller.dictionarySyncRunning { ProgressView() }
                    Text(controller.lastDictionarySyncStatus)
                }
                if let date = controller.lastDictionarySyncDate {
                    Text("上次成功：" + date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Button("立即同步") { controller.syncDictionaryNow() }
                    .disabled(controller.dictionarySyncRunning || !controller.settings.dictionarySyncEnabled)
            }
            SettingsCard(icon: "plus", title: "添加热词") {
                HStack(spacing: 10) {
                    TextField("输入人名、机构或专有名词", text: $newWord)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit(addWord)
                    Button(action: addWord) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Theme.accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            HStack {
                Text("全部热词")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(controller.settings.dictionaryWords.count) 个")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 4)

            LazyVGrid(columns: dictionaryColumns, spacing: 10) {
                ForEach(controller.settings.dictionaryWords, id: \.self) { word in
                    dictionaryWordCard(word)
                }
            }

            SettingsCard(icon: "arrow.triangle.2.circlepath", title: "添加纠错对") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("识别常错的固定搭配,不分大小写,每次都会替换,不依赖整理模型判断。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                    HStack(spacing: 8) {
                        TextField("识别成什么", text: $correctionSource)
                            .textInputAutocapitalization(.never)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                        TextField("该写成什么", text: $correctionTarget)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.done)
                            .onSubmit(addCorrection)
                    }
                    Button(action: addCorrection) {
                        Text("添加").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(correctionSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || correctionTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if !allCorrections.isEmpty {
                HStack {
                    Text("纠错对")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("\(allCorrections.count) 个")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 4)
                Text("手动添加的,和从历史修正/其它设备学到的,统一在这里管理,均可点开改写法、可删除。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 4)

                LazyVStack(spacing: 10) {
                    ForEach(allCorrections, id: \.source) { pair in
                        correctionCard(pair)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("立即同步") {
                        controller.syncDictionaryNow()
                        Haptics.selection()
                    }
                    Button("导入…") {
                        isImporting = true
                        Haptics.selection()
                    }
                    Button("导出…") {
                        exportDocument = DictionaryJSONDocument(backup: controller.dictionaryBackup)
                        isExporting = true
                        Haptics.selection()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json, .plainText]) { result in
            guard case .success(let url) = result else { return }
            importWords(from: url)
        }
        .alert("确认合并词典备份", isPresented: $showImportPreview) {
            Button("取消", role: .cancel) { pendingImport = nil }
            Button("合并导入") {
                if let backup = pendingImport { importMessage = controller.importDictionaryBackup(backup) }
                pendingImport = nil
                showImportMessage = true
            }
        } message: { Text(importPreview) }
        .alert("词典导入", isPresented: $showImportMessage) {
            Button("好", role: .cancel) {}
        } message: { Text(importMessage) }
        .fileExporter(isPresented: $isExporting, document: exportDocument,
                      contentType: .json, defaultFilename: "shall-we-talk-dictionary") { result in
            if case .failure(let error) = result { importMessage = "导出失败：" + error.localizedDescription; showImportMessage = true }
        }
    }

    /// 两端共用完整备份格式；兼容旧词表与纯文本，先预览再合并。
    private func importWords(from url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let backup = try DictionaryBackup.parse(data, isJSON: url.pathExtension.lowercased() == "json")
            pendingImport = backup
            importPreview = backup.preview(mergingInto: controller.dictionaryBackup).message
            showImportPreview = true
        } catch {
            importMessage = error.localizedDescription
            showImportMessage = true
        }
    }

    @ViewBuilder
    private func dictionaryWordCard(_ word: String) -> some View {
        if editingWord == word {
            VStack(alignment: .leading, spacing: 12) {
                TextField("热词", text: $editingDraft)
                    .font(.system(size: 16, weight: .medium))
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit { saveEdit(word) }
                HStack(spacing: 16) {
                    Button("删除", role: .destructive) { deleteWord(word) }
                    Spacer()
                    Button("取消") { editingWord = nil }
                    Button("保存") { saveEdit(word) }
                        .fontWeight(.semibold)
                        .disabled(editingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .font(.system(size: 14))
            }
            .padding(14)
            .cardSurface(radius: 15)
        } else {
            Button {
                editingWord = word
                editingDraft = word
                Haptics.selection()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text(word)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cardSurface(radius: 15)
        }
    }

    private func addWord() {
        guard controller.settings.addDictionaryWord(newWord) else { return }
        newWord = ""
        controller.publishDictionaryToKeyboard()
        controller.scheduleDictionarySync(reason: "词典编辑")
        Haptics.impact(.light)
    }

    private func saveEdit(_ oldWord: String) {
        guard controller.settings.updateDictionaryWord(oldWord, to: editingDraft) else { return }
        editingWord = nil
        controller.publishDictionaryToKeyboard()
        controller.scheduleDictionarySync(reason: "词典编辑")
        Haptics.impact(.light)
    }

    private func deleteWord(_ word: String) {
        controller.settings.deleteDictionaryWord(word)
        editingWord = nil
        controller.publishDictionaryToKeyboard()
        controller.scheduleDictionarySync(reason: "词典编辑")
        Haptics.impact(.medium)
    }

    /// 纠错对卡片(2026-08-19 统一,不再区分"替换词组"/"已学到的纠错对"两套卡片)。
    /// 点行(除 xmark 外)进入编辑态,"识别成什么"(source)和"该写成什么"(target)
    /// 都能改。保存时如果 source 没变,按原 source 覆盖写入 `settings.manualCorrections`
    /// (见 `addManualCorrection`);如果 source 被改了,视为"重命名"——新 source 单独
    /// 新增一条,旧 source 走 `controller.deleteCorrection` 摘除并屏蔽,防止旧的错误
    /// source 作为学习/同步残留重新冒出来。不管这条原先是手动、本机学习还是云端同步来的,
    /// 保存后统一变成手动版本,合并时优先级最高,立刻生效,同步落盘后也会覆盖云端与其它
    /// 设备上的旧版本。xmark 走 `controller.deleteCorrection`,同样不分来源统一处理:
    /// 摘出手动列表 + 记入屏蔽名单,阻止本机再挖出同一条、也阻止同步把云端旧版本带回来
    /// (见 `MobileSettingsStore.deleteCorrection` 与 `DictionarySync.reconcileCorrections`
    /// 的 `blocked` 参数)。
    @ViewBuilder
    private func correctionCard(_ pair: LearnedCorrection) -> some View {
        if editingCorrectionSource == pair.source {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    TextField("识别成什么", text: $editingCorrectionSourceDraft)
                        .textInputAutocapitalization(.never)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                    TextField("该写成什么", text: $editingCorrectionDraft)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit { saveCorrectionEdit(pair) }
                }
                HStack(spacing: 16) {
                    Button("删除", role: .destructive) {
                        controller.deleteCorrection(source: pair.source)
                        editingCorrectionSource = nil
                        Haptics.impact(.medium)
                    }
                    Spacer()
                    Button("取消") { editingCorrectionSource = nil }
                    Button("保存") { saveCorrectionEdit(pair) }
                        .fontWeight(.semibold)
                        .disabled(editingCorrectionSourceDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || editingCorrectionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .font(.system(size: 14))
            }
            .padding(14)
            .cardSurface(radius: 15)
        } else {
            HStack(spacing: 10) {
                Button {
                    editingCorrectionSource = pair.source
                    editingCorrectionSourceDraft = pair.source
                    editingCorrectionDraft = pair.target
                    Haptics.selection()
                } label: {
                    HStack(spacing: 10) {
                        Text(pair.source)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                        Text(pair.target)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.accent)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    controller.deleteCorrection(source: pair.source)
                    Haptics.impact(.medium)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .cardSurface(radius: 15)
        }
    }

    private func saveCorrectionEdit(_ pair: LearnedCorrection) {
        let newSource = editingCorrectionSourceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard controller.settings.addManualCorrection(source: newSource, target: editingCorrectionDraft) else { return }
        // source 被改名了:旧 source 必须摘除+屏蔽,否则它作为学习/同步的残留还会重新冒出来,
        // 变成"改了一条却多出一条旧的"。source 没变时不用碰旧记录,addManualCorrection
        // 本身就是按 source 覆盖式更新。
        if newSource.caseInsensitiveCompare(pair.source) != .orderedSame {
            controller.deleteCorrection(source: pair.source)
        }
        editingCorrectionSource = nil
        controller.scheduleDictionarySync(reason: "纠错对手动修正")
        Haptics.impact(.light)
    }

    private func addCorrection() {
        guard controller.settings.addManualCorrection(source: correctionSource, target: correctionTarget) else { return }
        correctionSource = ""
        correctionTarget = ""
        controller.scheduleDictionarySync(reason: "词典编辑")
        Haptics.impact(.light)
    }
}

/// 系统分享层使用完整备份，解析与合并规则由两端共用的 core 实现。
struct DictionaryJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var backup: DictionaryBackup
    init(backup: DictionaryBackup) { self.backup = backup }
    init(configuration: ReadConfiguration) throws {
        backup = try DictionaryBackup.parse(configuration.file.regularFileContents ?? Data(), isJSON: true)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(backup))
    }
}

private struct KeyboardSettingsPage: View {
    var body: some View {
        SettingsDetailPage(title: "键盘") {
            SettingsCard(icon: "keyboard", title: "键盘") {
                Text("启用键盘:设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → Shall We Talk,并打开「允许完全访问」(用于把 Shall We Talk 结果传回键盘插入)。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

private struct DiagnosticsSettingsPage: View {
    @EnvironmentObject var controller: DictationController
    /// 汇总最近这么多条记录的耗时,足够反映近况又不至于被很久以前的网络状况稀释。
    private static let recentSampleSize = 20

    var body: some View {
        SettingsDetailPage(title: "诊断") {
            SettingsCard(icon: "waveform.path.ecg", title: "诊断") {
                NavigationLink { DiagLogView() } label: {
                    SettingsNavRow(title: "诊断日志")
                }
                .buttonStyle(.plain)
                Text("键盘语音出问题时:先复现一两次,再进来「复制全部」把日志发给开发者。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            SettingsCard(icon: "speedometer", title: "耗时") {
                Text(latencySummary)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// 最近 N 条记录的平均/最差分段耗时,纯文本汇总(不做图表)。records 是新→旧排序,
    /// 直接取前 N 条即"最近 N 条"。
    private var latencySummary: String {
        let recent = controller.history.records.prefix(Self.recentSampleSize).compactMap { $0.metrics }
        guard !recent.isEmpty else { return "暂无耗时数据,完成几次口述后再来看。" }

        func stat(_ label: String, _ values: [Int]) -> String? {
            guard !values.isEmpty else { return nil }
            let avg = values.reduce(0, +) / values.count
            let worst = values.max()!
            return "\(label) 平均 \(String(format: "%.1f", Double(avg) / 1000))s / 最差 \(String(format: "%.1f", Double(worst) / 1000))s"
        }

        let records = controller.history.records.prefix(Self.recentSampleSize)
        let failed = records.filter { $0.cleanupStatus == .failed }.count
        let skipped = records.filter { $0.cleanupStatus == .skipped }.count
        var lines = ["最近 \(recent.count) 条有耗时记录；未整理完成 \(failed) 条，主动跳过 \(skipped) 条"]
        if let s = stat("识别", recent.compactMap { $0.asrFinalMillis }) { lines.append(s) }
        let completedCleanup = records.filter { $0.cleanupStatus == .succeeded }
            .compactMap { $0.metrics?.firstCleanupPass?.elapsedMillis }
        if let s = stat("整理成功", completedCleanup) { lines.append(s) }
        let failedCleanup = records.filter { $0.cleanupStatus == .failed }
            .compactMap { $0.metrics?.firstCleanupPass?.elapsedMillis }
        if let s = stat("整理失败等待", failedCleanup) { lines.append(s) }
        if let s = stat("总计", recent.compactMap { $0.totalMillis }) { lines.append(s) }
        return lines.joined(separator: " · ")
    }
}

// MARK: - 诊断日志(键盘⇄App 语音链路排障,数据来自 DiagLog 共享文件)

struct DiagLogView: View {
    @State private var lines: [String] = []
    @State private var copied = false

    var body: some View {
        List {
            if lines.isEmpty {
                Text("暂无日志。先复现一次键盘语音问题,再回到这里下拉刷新。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // 倒序展示:最新一行在最上,方便直接看到刚发生的故障
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
            }
        }
        .listStyle(.plain)
        .navigationTitle("诊断日志")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(copied ? "已复制" : "复制全部") {
                    // 复制按时间正序,阅读顺序自然
                    UIPasteboard.general.string = lines.reversed().joined(separator: "\n")
                    Haptics.selection()
                    copied = true
                }
                .disabled(lines.isEmpty)
                Button("清空日志", role: .destructive) {
                    DiagLog.clear()
                    lines = []
                }
            }
        }
        .onAppear { reload() }
        .refreshable { reload() }
    }

    private func reload() {
        lines = DiagLog.readMerged().reversed()
        copied = false
    }
}
