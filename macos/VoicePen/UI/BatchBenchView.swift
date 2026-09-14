import AppKit
import SwiftUI

/// 批量基准窗口(代码控制,菜单打开)
@MainActor
final class BatchBenchWindowController {
    private let window: NSWindow

    init(appState: AppState) {
        let root = BatchBenchView(bench: appState.batchBench).environmentObject(appState)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 660),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "批量基准 · 模型速度对比"
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.isReleasedWhenClosed = false
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct BatchBenchView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var bench: BatchBench
    @State private var selectedIDs: Set<UUID> = []
    @State private var repeats = 3

    private var clips: [DictationRecord] { appState.history.clipsWithAudio }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    clipPicker
                    runBar
                    if !bench.asrRows.isEmpty { asrTable }
                    if !bench.llmRows.isEmpty { llmTable }
                    if !bench.comboRows.isEmpty { comboTable }
                }
                .padding(18)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .onAppear {
            if selectedIDs.isEmpty {
                selectedIDs = Set(clips.prefix(8).map(\.id))   // 默认最近 8 段
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("离线批量:重放历史音频,把每个 ASR × 每个 LLM 跑一遍,多次取中位数,主排速度。")
                .font(.callout).foregroundStyle(Theme.textPrimary)
            HStack(spacing: 10) {
                Text("候选:识别 \(bench.asrCandidates.count) 个 · 整理 \(bench.llmCandidates.count) 个")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Button("重新载入候选") { bench.seedCandidates() }
                    .font(.caption)
                Button("打开配置文件(加更多模型)") {
                    bench.writeConfigTemplateIfNeeded()
                    NSWorkspace.shared.activateFileViewerSelecting([BatchBench.externalConfigURL])
                }
                .font(.caption)
            }
            if bench.asrCandidates.isEmpty {
                Text("⚠️ 没有可用 ASR 候选:请先在设置里配置火山凭证或 OpenAI 兼容 ASR。")
                    .font(.caption).foregroundStyle(Theme.warn)
            }
        }
    }

    // MARK: 音频选择

    private var clipPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("测试音频(\(selectedIDs.count)/\(clips.count) 选中)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("全选") { selectedIDs = Set(clips.map(\.id)) }.font(.caption)
                Button("最近8") { selectedIDs = Set(clips.prefix(8).map(\.id)) }.font(.caption)
                Button("清空") { selectedIDs = [] }.font(.caption)
            }
            if clips.isEmpty {
                Text("暂无带音频的历史。先在主界面口述几段(且设置里「留存音频」是开的)。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(clips.prefix(40)) { rec in
                        Button {
                            if selectedIDs.contains(rec.id) { selectedIDs.remove(rec.id) }
                            else { selectedIDs.insert(rec.id) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selectedIDs.contains(rec.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIDs.contains(rec.id) ? Theme.accent : Theme.textSecondary)
                                Text(rec.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2.monospaced()).foregroundStyle(Theme.textSecondary)
                                Text(rec.rawText.isEmpty ? "(无原文)" : rec.rawText)
                                    .font(.caption).foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        Divider().opacity(0.15)
                    }
                }
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 0.5))
            }
        }
    }

    // MARK: 运行控制

    private var runBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Stepper("每项重复 \(repeats) 次", value: $repeats, in: 1...9)
                    .font(.caption).fixedSize()
                Button(bench.isRunning ? "运行中…" : "开始跑批") {
                    let picked = clips.filter { selectedIDs.contains($0.id) }
                    bench.run(clips: picked, repeats: repeats)
                }
                .disabled(bench.isRunning || selectedIDs.isEmpty || bench.asrCandidates.isEmpty)
                .keyboardShortcut(.defaultAction)
                if let path = bench.lastReportPath {
                    Button("打开报告") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }.font(.caption)
                }
            }
            if bench.isRunning || bench.progress > 0 {
                ProgressView(value: bench.progress).tint(Theme.accent)
                Text(bench.progressText).font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            Text("提示:重复次数越多越稳(压网络抖动),但更慢。音频越多样越能反映真实差距。")
                .font(.caption2).foregroundStyle(Theme.textSecondary.opacity(0.85))
        }
    }

    // MARK: 结果表

    private var asrTable: some View {
        resultSection(title: "语音识别 · 按中位耗时升序") {
            headerRow(["模型", "中位ms", "最快", "最慢", "成功"])
            ForEach(bench.asrRows) { r in
                dataRow([r.name, "\(r.medianMs)", "\(r.minMs)", "\(r.maxMs)", "\(r.okRuns)/\(r.totalRuns)"],
                        highlight: r.id == bench.asrRows.first?.id)
            }
        }
    }

    private var llmTable: some View {
        resultSection(title: "文字整理 · 按总耗时升序") {
            headerRow(["模型", "首字ms", "总ms", "成功"])
            ForEach(bench.llmRows) { r in
                dataRow([r.name, "\(r.medianTTFT)", "\(r.medianTotal)", "\(r.okRuns)/\(r.totalRuns)"],
                        highlight: r.id == bench.llmRows.first?.id)
            }
        }
    }

    private var comboTable: some View {
        resultSection(title: "端到端组合 · ASR中位 + LLM总耗时中位,升序") {
            headerRow(["ASR", "LLM", "合计ms"])
            ForEach(bench.comboRows.prefix(12)) { c in
                dataRow([c.asrName, c.llmName, "\(c.endToEndMs)"],
                        highlight: c.id == bench.comboRows.first?.id)
            }
        }
    }

    // MARK: 小组件

    private func resultSection<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
            VStack(spacing: 2) { content() }
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 0.5))
        }
    }

    private func headerRow(_ cols: [String]) -> some View {
        HStack {
            ForEach(Array(cols.enumerated()), id: \.offset) { i, c in
                Text(c).font(.caption2.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: i == 0 ? .leading : .trailing)
            }
        }
    }

    private func dataRow(_ cols: [String], highlight: Bool) -> some View {
        HStack {
            ForEach(Array(cols.enumerated()), id: \.offset) { i, c in
                Text(c)
                    .font(i == 0 ? .caption : .caption.monospaced())
                    .foregroundStyle(highlight ? Theme.accent : Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: i == 0 ? .leading : .trailing)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}
