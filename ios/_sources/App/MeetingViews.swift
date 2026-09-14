import SwiftUI
import UIKit
import ShallWeTalkCore

// MARK: - 页 2「会议」

struct MeetingTab: View {
    @EnvironmentObject var meetingController: MeetingRecordingController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pendingUndo: PendingUndo?

    var body: some View {
        NavigationStack {
            Group {
                if meetingController.isActive {
                    MeetingRecordingSessionView()
                } else if meetingController.store.meetings.isEmpty {
                    emptyState
                } else {
                    meetingList
                }
            }
            .safeAreaInset(edge: .top) {
                if let error = meetingController.store.persistenceError {
                    HStack {
                        Text(error).font(.caption)
                        Button("重试保存") { meetingController.store.flush() }
                    }.padding().background(Theme.bg)
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(meetingController.isActive ? "正在录音" : "会议记录")
            .toolbar {
                if !meetingController.isActive {
                    ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink { MeetingSettingsPage() } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .tint(Theme.accent)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !meetingController.isActive { recordDock }
            }
            .undoBanner($pendingUndo)
        }
        .quietInkNavigationChrome()
        .tint(Theme.accent)
    }

    private var emptyState: some View {
        VStack(spacing: Space.md) {
            Image(systemName: "person.wave.2")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("会议记录")
                .font(.title3.weight(.semibold))
                .tracking(-0.3)
                .foregroundStyle(Theme.textPrimary)
            Text("长会议、访谈、投资人电话都可以录下来,自动整理成带时间线的纪要。\n来电会自动暂停,并在通话结束后自动续录。")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var meetingList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(meetingController.store.meetings) { meeting in
                    NavigationLink { MeetingDetailView(meetingID: meeting.id) } label: {
                        MeetingRow(meeting: meeting)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { delete(meeting) } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, Space.lg - 4)
            .padding(.top, 4)
            .padding(.bottom, 140)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.standard, value: meetingController.store.meetings)
    }

    private func delete(_ meeting: MeetingRecord) {
        Haptics.impact(.light)
        _ = withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.standard) {
            meetingController.delete(meetingID: meeting.id)
        }
        pendingUndo = nil // 会议音频体积大,不提供撤删,swipe 前系统已有二次确认手势成本
    }

    // MARK: - 起录坞

    @ViewBuilder
    private var recordDock: some View {
        Button {
            Haptics.impact(.medium)
            meetingController.start()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.wave.2.fill")
                Text("开始会议录音").quietHeadline()
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.accentGradient, in: Capsule())
        }
        .buttonStyle(.pressable)
        .padding(.horizontal, Space.lg - 4)
        .padding(.bottom, 8)
    }
}

private struct MeetingRow: View {
    let meeting: MeetingRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(meeting.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: Space.sm)
                stateBadge
            }
            if let oneLine = meeting.summary?.oneLine, !oneLine.isEmpty {
                Text(oneLine)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            Text(footnote)
                .quietFootnote()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var footnote: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        var parts = [f.string(from: meeting.startedAt)]
        let duration = MeetingTranscript.totalSpeechDuration(meeting.segments)
        if duration > 0 { parts.append("时长 \(Self.durationText(duration))") }
        let speakerCount = Set(meeting.segments.flatMap { $0.utterances.compactMap(\.speakerID) }).count
        if speakerCount > 0 { parts.append("\(speakerCount) 位说话人") }
        return parts.joined(separator: " · ")
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)小时\(m)分钟" : "\(m)分钟"
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch meeting.state {
        case .recording, .finalizingTranscript, .summarizing:
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.6)
                Text(stateLabel).quietFootnote()
            }
        case .needsFinalize, .failed:
            Text(stateLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.warn)
        default:
            EmptyView()
        }
    }

    private var stateLabel: String {
        switch meeting.state {
        case .recording: return "录音中"
        case .finalizingTranscript: return "转写中"
        case .summarizing: return "生成纪要中"
        case .needsFinalize: return "录音不完整"
        case .failed: return "处理失败"
        default: return ""
        }
    }
}

// MARK: - 录制中专用界面

/// 录制中不再把历史列表与「开始」入口同时留在画面上。这个界面只表达一件事：
/// 当前这一场会议正在录、已转出的草稿是什么，以及如何结束（或在中断后继续）。
private struct MeetingRecordingSessionView: View {
    @EnvironmentObject var meetingController: MeetingRecordingController
    @State private var transcriptAnchor = UUID()

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    if meetingController.phase == .recording {
                        RecordingDot(showsGlow: true)
                    } else {
                        ProgressView().scaleEffect(0.8)
                    }
                    Text(statusTitle)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(elapsedText)
                        .font(.system(size: 17, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                HStack {
                    Text(meetingController.statusNote ?? "正在准备…")
                        .quietFootnote()
                    Spacer()
                    LiveWaveformTicks(level: meetingController.audioLevel, tickCount: 16, maxHeight: 26)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("实时转写").quietSectionLabel()
                    Spacer()
                    Text("端侧草稿").quietFootnote()
                }
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if meetingController.liveTranscript.isEmpty {
                                Text(placeholderText)
                                    .quietBody()
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
                            } else {
                                Text(meetingController.liveTranscript)
                                    .quietBody()
                                    .foregroundStyle(Theme.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear.frame(height: 1).id(transcriptAnchor)
                        }
                    }
                    .onChange(of: meetingController.liveTranscript) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(transcriptAnchor, anchor: .bottom)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .cardSurface()

            HStack(spacing: 10) {
                if meetingController.phase == .pausedByInterruption {
                    Button {
                        Haptics.impact(.medium)
                        meetingController.resumeRecording()
                    } label: {
                        Text("继续录音").quietHeadline().foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Theme.accentGradient, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                }
                Button(role: .destructive) {
                    Haptics.impact(.medium)
                    meetingController.stop()
                } label: {
                    Text("结束会议").quietHeadline().foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Theme.dangerGradient, in: Capsule())
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(.horizontal, Space.lg - 4)
        .padding(.top, Space.md)
        .padding(.bottom, 16)
    }

    private var statusTitle: String {
        switch meetingController.phase {
        case .starting: return "正在启动录音"
        case .recording: return "会议录音中"
        case .pausedByInterruption: return "录音已暂停"
        case .finalizing: return "正在结束会议"
        case .idle: return "会议录音"
        }
    }

    private var placeholderText: String {
        switch meetingController.phase {
        case .starting: return "正在连接麦克风…"
        case .pausedByInterruption: return "录音已暂停。恢复后，新的文字会继续显示在这里。"
        default: return "端侧语音识别正在生成草稿。第一段文字通常会在约 12 秒音频后出现。"
        }
    }

    private var elapsedText: String {
        let total = Int(meetingController.elapsed)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - 会议详情

struct MeetingDetailView: View {
    let meetingID: UUID
    @EnvironmentObject var meetingController: MeetingRecordingController
    @Environment(\.dismiss) private var dismiss
    @State private var isEditingTranscript = false
    @State private var editedText = ""
    @State private var showDeleteConfirm = false
    @State private var audioExport: MeetingAudioExportItem?
    @State private var audioExportError: String?

    private var meeting: MeetingRecord? {
        meetingController.store.meetings.first(where: { $0.id == meetingID })
    }

    var body: some View {
        Group {
            if let meeting {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        audioArchiveCard(meeting)
                        summaryCard(meeting)
                        transcriptSection(meeting)
                    }
                    .padding(.horizontal, Space.lg - 4)
                    .padding(.vertical, Space.md)
                    .padding(.bottom, 40)
                }
                .background(Theme.bg.ignoresSafeArea())
                .navigationTitle(meeting.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button("重新生成摘要") { meetingController.regenerateSummary(meetingID: meetingID) }
                            Button("重新转写并生成摘要") { meetingController.finalizeIfNeeded(meetingID: meetingID) }
                            Button("删除会议", role: .destructive) { showDeleteConfirm = true }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .tint(Theme.accent)
                    }
                }
                .confirmationDialog("删除这场会议记录？音频与转写都会被删除，且无法恢复。",
                                    isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                    Button("删除", role: .destructive) {
                        if meetingController.delete(meetingID: meetingID) { dismiss() }
                    }
                }
            } else {
                Text("会议记录已删除").foregroundStyle(Theme.textSecondary)
            }
        }
        .sheet(item: $audioExport) { item in
            MeetingAudioShareSheet(url: item.url)
        }
        .alert("无法导出完整录音", isPresented: Binding(
            get: { audioExportError != nil },
            set: { if !$0 { audioExportError = nil } }
        )) {
            Button("好", role: .cancel) { audioExportError = nil }
        } message: {
            Text(audioExportError ?? "")
        }
    }

    // MARK: 原始录音存档

    @ViewBuilder
    private func audioArchiveCard(_ meeting: MeetingRecord) -> some View {
        let segmentCount = meeting.segments.count
        let archiveURL = meetingController.store.completeAudioURL(for: meeting.id)
        let archiveSize = (try? archiveURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let archived = archiveSize > 44
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("原始录音", systemImage: "waveform.badge.checkmark")
                    .quietSectionLabel()
                Spacer()
                Text(archived ? "已封存" : "待合并")
                    .quietFootnote()
                    .foregroundStyle(archived ? Theme.accent : Theme.textSecondary)
            }
            Text("录音先落盘，识别或纪要生成失败不会删除。技术分段会合并为一份 WAV，方便保存或重新转写。")
                .quietFootnote()
            Button {
                exportCompleteAudio(meeting.id)
            } label: {
                Label(archived ? "保存完整录音" : "合并并保存完整录音",
                      systemImage: "square.and.arrow.up")
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .disabled(segmentCount == 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func exportCompleteAudio(_ meetingID: UUID) {
        Task {
            do {
                let url = try await meetingController.completeAudioArchiveForExport(meetingID: meetingID)
                audioExport = MeetingAudioExportItem(url: url)
            } catch {
                audioExportError = error.localizedDescription
            }
        }
    }

    // MARK: 摘要

    @ViewBuilder
    private func summaryCard(_ meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("会议纪要").quietSectionLabel()
                Spacer()
                if meeting.state == .summarizing {
                    ProgressView().scaleEffect(0.7)
                }
            }
            if let summary = meeting.summary {
                summaryContent(summary)
            } else if meeting.state == .summarizing {
                Text("正在生成纪要…").quietFootnote()
            } else if let raw = meeting.summaryRaw, !raw.isEmpty {
                Text(raw).quietBody().foregroundStyle(Theme.textPrimary)
            } else if meeting.state == .needsFinalize || meeting.state == .failed {
                VStack(alignment: .leading, spacing: 8) {
                    if let error = meeting.lastError { Text(error).quietFootnote() }
                    Button(meeting.state == .needsFinalize || meeting.state == .failed
                           ? "重新转写并生成纪要" : "补生成摘要") {
                        meetingController.finalizeIfNeeded(meetingID: meetingID)
                    }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            } else {
                Text("会议结束后自动生成").quietFootnote()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    @ViewBuilder
    private func summaryContent(_ summary: MeetingSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !summary.oneLine.isEmpty {
                Text(summary.oneLine).quietBody().foregroundStyle(Theme.textPrimary)
            }
            if !summary.timeline.isEmpty {
                sectionBlock("行程") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(summary.timeline.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 10) {
                                Text(item.at)
                                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 44, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.topic).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                                    if !item.detail.isEmpty {
                                        Text(item.detail).font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if !summary.keyPoints.isEmpty {
                sectionBlock("关键要点") { bulletList(summary.keyPoints) }
            }
            if !summary.decisions.isEmpty {
                sectionBlock("决议") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(summary.decisions.enumerated()), id: \.offset) { _, decision in
                            HStack(alignment: .top, spacing: 6) {
                                Text(decision.status == "已确认" ? "已确认" : "待定")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(decision.status == "已确认" ? Theme.accent : Theme.warn)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background((decision.status == "已确认" ? Theme.accent : Theme.warn).opacity(0.12),
                                               in: RoundedRectangle(cornerRadius: 4))
                                Text(decision.text).quietBody().foregroundStyle(Theme.textPrimary)
                            }
                        }
                    }
                }
            }
            if !summary.actionItems.isEmpty {
                sectionBlock("待办事项") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.task).quietBody().foregroundStyle(Theme.textPrimary)
                                let meta = [item.owner, item.deadline].compactMap { $0 }.joined(separator: " · ")
                                if !meta.isEmpty { Text(meta).quietFootnote() }
                            }
                        }
                    }
                }
            }
            if !summary.openQuestions.isEmpty {
                sectionBlock("未决问题") { bulletList(summary.openQuestions) }
            }
        }
    }

    private func sectionBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).quietSectionLabel()
            content()
        }
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    Text("·").foregroundStyle(Theme.textTertiary)
                    Text(item).quietBody().foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }

    // MARK: 转写

    @ViewBuilder
    private func transcriptSection(_ meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("完整转写").quietSectionLabel()
                Spacer()
                if !meeting.isFinalTranscript, meeting.state != .recording {
                    Text("端侧草稿").quietFootnote()
                }
                Button(isEditingTranscript ? "取消" : "编辑") {
                    if isEditingTranscript {
                        isEditingTranscript = false
                    } else {
                        editedText = meeting.editedTranscriptText
                            ?? MeetingTranscript.displayText(segments: meeting.segments, meetingStartedAt: meeting.startedAt)
                        isEditingTranscript = true
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
            }

            if isEditingTranscript {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: $editedText)
                        .frame(minHeight: 240)
                        .font(.system(size: 15))
                        .padding(8)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.separator, lineWidth: 0.5))
                    HStack(spacing: 10) {
                        Button("保存并重新生成摘要") {
                            meetingController.saveEditedTranscript(meetingID: meetingID, text: editedText)
                            meetingController.regenerateSummary(meetingID: meetingID)
                            isEditingTranscript = false
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Theme.accentGradient, in: Capsule())

                        Button("仅保存") {
                            meetingController.saveEditedTranscript(meetingID: meetingID, text: editedText)
                            isEditingTranscript = false
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    }
                }
            } else if let edited = meeting.editedTranscriptText {
                Text(edited).quietBody().foregroundStyle(Theme.textPrimary)
            } else {
                transcriptLines(meeting)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func transcriptLines(_ meeting: MeetingRecord) -> some View {
        let lines = MeetingTranscript.lines(segments: meeting.segments, meetingStartedAt: meeting.startedAt)
        return LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 4) {
                    if line.isSegmentStart, let marker = boundaryMarker(for: line, in: meeting) {
                        Text(marker)
                            .quietFootnote()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 4)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Text(Self.timestamp(line.offsetMs))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 44, alignment: .leading)
                        Text(line.speakerLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                        Text(line.text).quietBody().foregroundStyle(Theme.textPrimary)
                    }
                }
            }
            if lines.isEmpty {
                Text(meeting.state == .recording ? "正在录音…" : "暂无转写内容").quietFootnote()
            }
        }
    }

    private func boundaryMarker(for line: MeetingTranscript.Line, in meeting: MeetingRecord) -> String? {
        guard let segment = meeting.segments.first(where: { $0.index == line.segmentIndex }),
              let ordered = meeting.segments.sorted(by: { $0.startedAt < $1.startedAt }).firstIndex(where: { $0.id == segment.id }),
              ordered > 0 else { return nil }
        let previous = meeting.segments.sorted(by: { $0.startedAt < $1.startedAt })[ordered - 1]
        guard let reason = previous.endReason else { return nil }
        return MeetingTranscript.boundaryMarker(for: reason, resumedAtOffsetMs: line.offsetMs)
    }

    private static func timestamp(_ ms: Int) -> String {
        let total = max(0, ms) / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - 会议设置

struct MeetingSettingsPage: View {
    @EnvironmentObject var meetingController: MeetingRecordingController
    @AppStorage("meetingSpeakerDiarization") private var speakerDiarization = true
    @AppStorage("meetingSummaryThinking") private var summaryThinking = true
    @State private var showClearAudioConfirm = false

    var body: some View {
        SettingsDetailPage(title: "会议记录") {
            SettingsCard(icon: "person.wave.2", title: "说话人分离") {
                Toggle("识别不同发言人", isOn: $speakerDiarization)
                Text("会议结束后的高精度转写会尝试区分发言人。基于单麦克风语音特征分离,重叠说话或距离较远时可能标错,请以人工核对为准。")
                    .quietFootnote()
            }
            SettingsCard(icon: "doc.text.magnifyingglass", title: "纪要生成") {
                Toggle("摘要生成时开启思考模式", isOn: $summaryThinking)
            }
            SettingsCard(icon: "externaldrive", title: "音频保留") {
                Text("原始录音永久保留。识别、整理、iCloud 同步和存储容量都不会自动删除音频；仅在您明确删除会议或确认清空时才会移除。")
                    .quietFootnote()
                Text("已占用 \(ByteCountFormatter.string(fromByteCount: Int64(meetingController.store.totalAudioBytes()), countStyle: .file))")
                    .quietFootnote()
                Button("清空所有会议音频（保留文字）", role: .destructive) { showClearAudioConfirm = true }
                    .font(.system(size: 15, weight: .semibold))
            }
            SettingsCard(icon: "icloud", title: "iCloud 同步") {
                Text(meetingController.lastCloudSyncStatus).quietFootnote()
                HStack(spacing: 16) {
                    Button("从 iCloud 拉取") { meetingController.syncFromCloud() }
                    Button("上传本机会议") { meetingController.syncToCloud() }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
            }
        }
        .confirmationDialog("清空所有会议音频？文字转写与摘要会保留,音频无法恢复。",
                            isPresented: $showClearAudioConfirm, titleVisibility: .visible) {
            Button("清空音频", role: .destructive) { meetingController.store.clearAllAudio() }
        }
    }
}

private struct MeetingAudioExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct MeetingAudioShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
