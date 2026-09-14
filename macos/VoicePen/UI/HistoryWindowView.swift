import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ShallWeTalkCore

/// 口述历史 / 语音备忘窗口(设计包 §Screens.4):双栏 master-detail,按日分组、全文搜索、
/// 查看原文、编辑最终稿(编辑即学习信号)。功能与改版前一一对应,只重做视觉。
struct HistoryWindowView: View {
    @EnvironmentObject var appState: AppState
    @State private var query = ""
    @State private var selection: UUID?
    // AppState also publishes live audio levels. Do not repeat full-text search and
    // calendar grouping on every unrelated recording/UI update.
    @State private var filtered: [DictationRecord] = []
    @State private var groups: [(String, [DictationRecord])] = []

    /// NSSavePanel 记住上次导出目录(用户自选,如 Obsidian vault;不硬编码路径)
    private static let exportDirectoryKey = "markdownExportDirectoryPath"

    /// 全文过滤逻辑与 iOS 共用 core.HistorySearch:多关键词空格分隔取 AND、大小写不敏感、中文子串。
    private func matchingRecords(_ records: [DictationRecord]) -> [DictationRecord] {
        let keywords = HistorySearch.keywords(from: query)
        guard !keywords.isEmpty else { return records }
        return records.filter {
            HistorySearch.matches(fields: [$0.finalText ?? $0.cleanText, $0.rawText],
                                  keywords: keywords)
        }
    }

    /// 按天分组,保持新→旧顺序
    private func refreshProjection(_ records: [DictationRecord]) {
        let matches = matchingRecords(records)
        var order: [String] = []
        var dict: [String: [DictationRecord]] = [:]
        for r in matches {
            let key = Self.dayString(r.date)
            if dict[key] == nil { order.append(key) }
            dict[key, default: []].append(r)
        }
        filtered = matches
        groups = order.map { ($0, dict[$0]!) }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ZStack {
                Theme.surface.ignoresSafeArea()
                if let sel = selection,
                   let r = appState.history.records.first(where: { $0.id == sel }) {
                    RecordDetailView(record: r)
                        .id(r.id) // 切换记录时重建编辑状态
                } else {
                    Text("选择左侧一条记录查看或编辑")
                        .quietFootnote()
                }
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .safeAreaInset(edge: .top, spacing: 0) {
            HistoryPersistenceBanner(history: appState.history)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    appState.syncHistoryFromCloud()
                } label: {
                    if appState.isHistorySyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath.icloud")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 28, height: 28)
                .hoverHighlight(radius: Radius.toolbarTile)
                .disabled(appState.isHistorySyncing)
                .help("与 iCloud 双向同步口述历史(拉取其他设备的记录,并补传本机记录)")
            }
            ToolbarItem {
                Button {
                    exportMarkdown()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .frame(width: 28, height: 28)
                .hoverHighlight(radius: Radius.toolbarTile)
                .help("把当前筛选结果与待办导出为 Markdown 文件(可直接存进 Obsidian vault)")
                .disabled(filtered.isEmpty && appState.todos.items.isEmpty)
            }
            ToolbarItem {
                Button {
                    appState.toggle()
                } label: {
                    HStack(spacing: 6) {
                        if appState.status == .recording {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(.white).frame(width: 9, height: 9)
                        } else {
                            StaticWaveformTicks(count: 3, color: .white, tickWidth: 2, spacing: 2,
                                                heights: [6, 10, 7])
                        }
                        Text(appState.status == .recording ? "结束口述" : "新建口述")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.pressable)
                .help("直接口述一条备忘,自动存入历史")
            }
        }
        .navigationTitle("口述历史")
        // 云朵按钮的可感知反馈:正在同步… / 上次同步 HH:mm · 合并 N 条 / 失败原因
        .navigationSubtitle(appState.lastHistorySyncStatus)
        .quietWindowChrome()
        // Published delivers the new snapshot before HistoryStore.records is set;
        // use the emitted value, not a read of the still-old property.
        .onReceive(appState.history.$records) { refreshProjection($0) }
        .onChange(of: query) { refreshProjection(appState.history.records) }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            refreshProjection(appState.history.records)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            refreshProjection(appState.history.records)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            refreshProjection(appState.history.records)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshProjection(appState.history.records)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
            List(selection: $selection) {
                ForEach(groups, id: \.0) { day, records in
                    Section {
                        ForEach(records) { r in
                            HistoryRow(record: r, isSelected: selection == r.id)
                                .tag(r.id)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                        }
                    } header: {
                        Text(day).quietSectionLabel()
                    }
                }
                if filtered.isEmpty {
                    Text(query.isEmpty ? "还没有口述记录" : "没有匹配的记录")
                        .quietFootnote()
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
        }
        .background(Theme.bg)
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 320)
    }

    /// h30 r8 card 底 + 0.5pt 描边,放大镜 + 占位 12.5 inkTertiary(设计包新增,替换系统 .searchable 外观)
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            TextField("搜索口述内容", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.separator, lineWidth: 0.5))
        .padding(10)
    }

    private static func dayString(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天" }
        if cal.isDateInYesterday(date) { return "昨天" }
        return date.formatted(.dateTime.year().month().day())
    }

    /// 导出当前筛选结果 + 全部待办;生成逻辑在 core.MarkdownExport(与 iOS 同源,带 XCTest)。
    private func exportMarkdown() {
        let doc = MarkdownExport.document(
            records: matchingRecords(appState.history.records).map {
                .init(date: $0.date, text: $0.finalText ?? $0.cleanText, rawText: $0.rawText)
            },
            todos: appState.todos.items.map { .init(text: $0.text, done: $0.done) })

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = MarkdownExport.defaultFileName()
        if let path = UserDefaults.standard.string(forKey: Self.exportDirectoryKey) {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? doc.write(to: url, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(url.deletingLastPathComponent().path,
                                  forKey: Self.exportDirectoryKey)
    }
}

/// 侧栏行卡:r10,两行预览 13/18 ink + 时间 11 inkSecondary +「已修改」chip。
/// 选中 = accent@12% 填充 + 0.5pt accent@25% 描边;hover = ink@4%。
private struct HistoryRow: View {
    let record: DictationRecord
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.recognitionFailure != nil && record.cleanText.isEmpty ? "识别未完成，可重试" : String((record.finalText ?? record.cleanText).prefix(80)))
                .font(.system(size: 13)).lineSpacing(2.5)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(record.date, style: .time)
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                if record.finalText != nil {
                    Text("已修改")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.sidebarRowV)
        .padding(.vertical, Space.sidebarRowH)
        .background(
            RoundedRectangle(cornerRadius: Radius.sidebarRow, style: .continuous)
                .fill(isSelected ? Theme.accent.opacity(0.12)
                      : (hovering ? Theme.textPrimary.opacity(0.04) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sidebarRow, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.25) : .clear, lineWidth: 0.5)
        )
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .contentShape(Rectangle())
    }
}

struct RecordDetailView: View {
    @EnvironmentObject var appState: AppState
    let record: DictationRecord
    @State private var text = ""
    @State private var showRaw = false
    @State private var reprocessing = false
    @State private var reprocessingMessage: String?

    private var savedText: String { record.finalText ?? record.cleanText }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if record.cleanupStatus == .failed {
                HStack {
                    Text("识别完成，整理未完成")
                    Button(appState.recleaningRecordID == record.id ? "整理中…" : "重试整理") {
                        Task { await appState.retryCleanup(record: record) }
                    }.disabled(appState.recleaningRecordID != nil)
                }.font(.caption)
            }
            if let message = appState.cleanupRetryMessages[record.id] { Text(message).font(.caption) }
            if let reprocessingMessage { Text(reprocessingMessage).font(.caption) }
            HStack(spacing: 10) {
                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                if let summary = record.metrics?.compactSummary {
                    Text(summary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Toggle("查看 ASR 原文", isOn: $showRaw)
                    .toggleStyle(.checkbox)
                    .tint(Theme.accent)
                    .font(.system(size: 12))
            }

            if showRaw {
                ScrollView {
                    Text(record.rawText.isEmpty ? "(无原文)" : record.rawText)
                        .quietBody()
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.cardPaddingLG)
                }
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            } else {
                TextEditor(text: $text)
                    .quietBody()
                    .scrollContentBackground(.hidden)
                    .padding(Space.cardPaddingLG - 4)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            }

            HStack(spacing: 8) {
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(showRaw ? record.rawText : text, forType: .string)
                }
                .buttonStyle(.quietStroke)
                Button("复制为 Markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        MarkdownExport.recordMarkdown(
                            .init(date: record.date, text: text, rawText: record.rawText)),
                        forType: .string)
                }
                .buttonStyle(.quietStroke)
                Button(reprocessing ? "整理中…" : "重新整理") {
                    reprocessing = true
                    reprocessingMessage = nil
                    let raw = record.rawText
                    let editorAtStart = text
                    let recordID = record.id
                    Task {
                        let result = await appState.reclean(raw: raw, recordingDuration: record.recordingDuration ?? 0)
                        await MainActor.run {
                            // Do not replace unsaved typing or show a result for a
                            // record deleted/re-recognized during the request.
                            if !result.isEmpty, text == editorAtStart,
                               appState.history.records.contains(where: {
                                   $0.id == recordID && $0.rawText == raw
                               }) {
                                text = result; showRaw = false
                            } else if !result.isEmpty {
                                reprocessingMessage = "内容已更新，未覆盖当前编辑；请重新整理。"
                            }
                            reprocessing = false
                        }
                    }
                }
                .buttonStyle(.quietStroke)
                .disabled(reprocessing || record.rawText.isEmpty)
                .help("用当前整理设置对这条的 ASR 原文重新整理(测试新版分段/整理,结果显示在编辑框,可再保存)")
                if record.recognitionSource == .onDevice || record.recognitionFailure != nil {
                    Button(appState.recloudingRecordID == record.id ? "云端识别中…" : "用云端重新识别") {
                        Task { await appState.recognizeWithCloudAgain(record: record) }
                    }
                    .buttonStyle(.quietStroke)
                    .disabled(appState.recloudingRecordID != nil)
                    .help("使用本机保留的录音重新识别与整理")
                }
                Button("语音修改") { appState.beginVoiceEdit(record) }
                    .buttonStyle(.quietStroke)
                    .disabled(appState.status != .idle)
                    .help("说出修改要求；原文经 EditPass 安全判定后才会写回，可撤销")
                Button("保存修改") {
                    appState.history.updateFinalText(id: record.id, finalText: text)
                    appState.refreshAutoDictionary() // 修正是最强的入典信号
                    appState.cloudPush(id: record.id) // 编辑同步上云
                }
                .buttonStyle(.quietSolid)
                .disabled(showRaw || text == savedText)
                Spacer()
                Button("删除") {
                    appState.deleteHistory(id: record.id)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.danger)
            }

            Text("在这里的修改会被记录,用于个人词典、整理偏好和未来的发音分析。")
                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            if let path = record.asrCompletionPath {
                Label(path.displayName, systemImage: path.systemImage)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
            if let diagnostics = record.streamingDiagnostics {
                VStack(alignment: .leading, spacing: 2) {
                    Label(diagnostics.displayName,
                          systemImage: diagnostics.outcome == .completed ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(diagnostics.outcome == .completed ? Theme.textSecondary : Theme.danger)
                    Text(diagnostics.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .textSelection(.enabled)
                    if let timeline = diagnostics.timeline, !timeline.detail.isEmpty {
                        Text(timeline.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                            .textSelection(.enabled)
                    }
                }
            }
            if let failure = record.recognitionFailure {
                Text("识别未完成：\(failure)")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            if record.recognitionSource == .onDevice {
                Label("离线识别兜底", systemImage: "wifi.slash")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
            if let status = appState.voiceEditStatus {
                HStack {
                    Text(status).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    if status.contains("可撤销") { Button("撤销") { appState.undoLastVoiceEdit() }.buttonStyle(.plain) }
                }
            }
        }
        .padding(Space.windowMarginLG)
        .onAppear { text = savedText }
    }
}

private struct HistoryPersistenceBanner: View {
    @ObservedObject var history: HistoryStore

    var body: some View {
        if let message = history.persistenceError {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                Text(message).font(.callout)
                Spacer(minLength: 0)
                Button("重试保存") { history.retryPersistence() }
            }
            .padding(12)
            .background(Color.orange.opacity(0.12))
            .accessibilityElement(children: .contain)
        }
    }
}
