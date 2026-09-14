import SwiftUI
import AVFoundation

// MARK: - 待办卡片 v2「静墨 / Quiet Ink」(规格 §Screens.3 + 设计稿 Turn 4「4a/4b」为准)
//
// 每条待办是独立卡片,无勾选圈/圆框:
//  - 主文字 17/24 + 创建时间 13pt(完成态整体降对比,唯一完成标记 = 删除线)
//  - 播放原音三态胶囊(未播 / 播放中 / 无原音);归档中状态:现有数据模型无法与"无原音"区分,不新增状态
//  - 右侧 30pt 重新识别图标钮,处理中原位换进度环;失败时卡内追加一行红字 + 重试
//  - 左滑完成(连续进度、越过阈值触感+文案)/ 反向滑动删除(danger),同一手势按位移方向与进度实现
//  - 单点主文字原卡就地展开为编辑器(spring,无弹窗)
//  - 长按拖动的把手效果(scale + 阴影)由外部 isBeingDragged 驱动,拖拽机制本身仍是调用方的 .onDrag/.onDrop

struct TodoCard: View {
    let item: TodoItem
    let audioURL: URL?
    @ObservedObject var playback: AudioPlayback
    let prepareForPlayback: () -> Void
    let audioBlocked: Bool
    let isRefining: Bool
    let refineError: String?
    let isBeingDragged: Bool
    let onSaveText: (String) -> Void
    let onToggleDone: () -> Void
    let onDelete: () -> Void
    let onRefine: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isEditing = false
    @State private var draftText = ""
    @State private var dragOffset: CGFloat = 0
    @State private var dragAxis: SwipeAxis?
    @State private var crossedThreshold = false
    @State private var audioDuration: TimeInterval = 0

    private enum SwipeAxis { case horizontal, vertical }

    private let threshold: CGFloat = 96

    private var completeProgress: CGFloat { dragOffset < 0 ? min(1, -dragOffset / threshold) : 0 }
    private var deleteProgress: CGFloat { dragOffset > 0 ? min(1, dragOffset / threshold) : 0 }

    var body: some View {
        ZStack(alignment: dragOffset <= 0 ? .trailing : .leading) {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(swipeBackgroundColor)
            swipeIndicator
                .padding(.horizontal, 20)

            cardBody
                .padding(.horizontal, Space.md)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(isBeingDragged ? 0.18 : 0),
                        radius: isBeingDragged ? 26 : 2,
                        y: isBeingDragged ? 10 : 1)
                .scaleEffect(isBeingDragged ? 1.03 : 1)
                .offset(x: dragOffset)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.8),
                   value: isBeingDragged)
        .simultaneousGesture(swipeGesture)
        .task(id: audioURL) {
            guard let audioURL else {
                audioDuration = 0
                return
            }
            audioDuration = await loadAudioDuration(from: audioURL)
        }
    }

    // MARK: 卡片内容(静止态 / 编辑态)

    @ViewBuilder private var cardBody: some View {
        if isEditing {
            editingBody
        } else {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 9) {
                    // 删除线用 Text 原生修饰符(渲染进字串,先于任何 View 修饰符)——
                    // View 级 .strikethrough 走环境传播,在 LazyVStack 懒行缓存下 done 翻转时不刷新。
                    Text(item.text)
                        .strikethrough(item.done, color: titleColor)
                        .font(.system(size: 17))
                        .lineSpacing(2)   // 17pt → 行高 24
                        .foregroundStyle(titleColor)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { beginEditing() }

                    HStack(spacing: 10) {
                        if let audioURL {
                            QuietInkPlaybackPill(
                                state: playbackState,
                                isDisabled: audioBlocked
                            ) {
                                if !playback.isPlaying(item.id) && !audioBlocked { prepareForPlayback() }
                                playback.toggle(url: audioURL, id: item.id, blocked: audioBlocked)
                            }
                        } else {
                            QuietInkPlaybackPill(state: .unavailable, action: {})
                        }
                        Text(createdAtLabel)
                            .font(.system(size: 13))
                            .foregroundStyle(dateColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Spacer(minLength: 0)
                    }

                    if let refineError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.danger)
                            Text("重新识别失败：\(refineError)")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.danger)
                                .lineLimit(2)
                            Button("重试", action: onRefine)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .buttonStyle(.plain)
                        }
                    }
                }
                QuietInkRefineButton(isRefining: isRefining, action: onRefine)
            }
        }
    }

    private var editingBody: some View {
        VStack(alignment: .trailing, spacing: 12) {
            TextEditor(text: $draftText)
                .font(.system(size: 17))
                .lineSpacing(4)   // 17pt(系统行高≈22)→ 目标行高 26,与 quietBody 同参
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 78)
                .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 8) {
                Spacer()
                Button("取消") {
                    withAnimation(Motion.standard) { isEditing = false }
                }
                .font(.system(size: 14))
                .foregroundStyle(Color.inkAdaptive(lightOpacity: 0.55, darkOpacity: 0.5))
                .buttonStyle(.plain)

                Button {
                    onSaveText(draftText)
                    withAnimation(Motion.standard) { isEditing = false }
                } label: {
                    Text("保存")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.pressable)
            }
        }
    }

    private func beginEditing() {
        guard !isEditing else { return }
        draftText = item.text
        withAnimation(Motion.standard) { isEditing = true }
    }

    // MARK: 左滑完成 / 反向滑动删除(连续进度反馈,阈值 96pt)

    @ViewBuilder private var swipeIndicator: some View {
        if dragOffset < -4 {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .scaleEffect(0.7 + 0.5 * completeProgress)
                if completeProgress >= 1 {
                    Text(item.done ? "恢复" : "完成")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .transition(.opacity)
                }
            }
        } else if dragOffset > 4 {
            Image(systemName: "trash.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .opacity(min(1, deleteProgress * 2))
        }
    }

    private var swipeBackgroundColor: Color {
        if dragOffset < 0 { return Theme.accent.opacity(0.35 + 0.65 * completeProgress) }
        if dragOffset > 0 { return Theme.danger.opacity(0.35 + 0.65 * deleteProgress) }
        return .clear
    }

    private var swipeGesture: some Gesture {
        // 编辑态(TextEditor 展开)时不响应滑动,让手势交给文本选区/滚动。
        DragGesture(minimumDistance: 14, coordinateSpace: .local)
            .onChanged { value in
                guard !isEditing else { return }
                if dragAxis == nil {
                    dragAxis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                }
                guard dragAxis == .horizontal else { return }
                dragOffset = value.translation.width
                let over = abs(dragOffset) >= threshold
                if over != crossedThreshold {
                    crossedThreshold = over
                    if over { Haptics.impact(.light) }
                }
            }
            .onEnded { value in
                defer { dragAxis = nil; crossedThreshold = false }
                guard !isEditing, dragAxis == .horizontal else { return }
                let t = value.translation.width
                if t <= -threshold {
                    onToggleDone()
                    withAnimation(Motion.standard) { dragOffset = 0 }
                } else if t >= threshold {
                    onDelete()
                    withAnimation(Motion.standard) { dragOffset = 0 }
                } else {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Motion.bouncy) { dragOffset = 0 }
                }
            }
    }

    // MARK: 颜色令牌(完成态整体降对比:主文字 @38%,时间 @28%;未完成:时间 @40%)

    private var titleColor: Color {
        item.done ? Color.inkAdaptive(lightOpacity: 0.38, darkOpacity: 0.4) : Theme.textPrimary
    }
    private var dateColor: Color {
        item.done
            ? Color.inkAdaptive(lightOpacity: 0.28, darkOpacity: 0.3)
            : Color.inkAdaptive(lightOpacity: 0.4, darkOpacity: 0.4)
    }

    private var playbackState: QuietInkPlaybackPillState {
        guard playback.isPlaying(item.id) else {
            return .available(duration: timeLabel(audioDuration))
        }
        return .playing(
            elapsed: timeLabel(playback.currentTime),
            total: timeLabel(playback.duration),
            progress: playback.progress
        )
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private func loadAudioDuration(from url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    private var createdAtLabel: String {
        let calendar = Calendar.autoupdatingCurrent
        let components = calendar.dateComponents([.month, .day, .hour, .minute], from: item.createdAt)
        let time = String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
        if calendar.isDateInToday(item.createdAt) { return "今天 \(time)" }
        if calendar.isDateInYesterday(item.createdAt) { return "昨天 \(time)" }
        return "\(components.month ?? 0)月\(components.day ?? 0)日"
    }
}

// 播放与重新识别的视觉组件位于 Shared target；本文件只负责业务状态映射。
