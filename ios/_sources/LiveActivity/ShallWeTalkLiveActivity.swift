import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ShallWeTalkLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        ShallWeTalkLiveActivity()
    }
}

/// App 图标「静蓝底 · 波形」里那五根条,用代码画一遍。
///
/// 为什么不放资源:Live Activity 是独立 target,挂资源目录要改 project.yml 且两处易漂移;
/// 而这套几何本来就是写死的比例(见 §12.19),画出来比引资源更不容易走样。
/// 高度比取自定稿的 0.137/0.289/0.383/0.227/0.156,这里按最高一根归一化;
/// 首尾两根 55% 不透明度、条宽=间距,与图标和键盘就绪态圆内的波形是同一套语言。
private struct BrandWaveform: View {
    var height: CGFloat
    var tint: Color

    private static let ratios: [CGFloat] = [0.358, 0.755, 1.0, 0.593, 0.407]
    private static let opacities: [Double] = [0.55, 1, 1, 1, 0.55]

    var body: some View {
        let bar = max(1.5, height * 0.1224)
        HStack(alignment: .center, spacing: bar) {
            ForEach(Array(Self.ratios.enumerated()), id: \.offset) { index, ratio in
                Capsule(style: .continuous)
                    .fill(tint.opacity(Self.opacities[index]))
                    .frame(width: bar, height: max(bar, height * ratio))
            }
        }
        .frame(height: height)
        .accessibilityLabel("Shall We Talk")
    }
}

struct ShallWeTalkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CaptureActivityAttributes.self) { context in
            HStack(spacing: 12) {
                // 品牌标识优先于状态图标:用户要能一眼看出"是哪个 App 在录音"
                // (2026-08-07 要求)。录音/启动用品牌波形,终态才换回结果图标。
                brandOrStatusIcon(context.state.stage)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline(context.state.stage))
                        .font(.headline)
                    Text(context.state.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                if context.state.stage == .recording {
                    Text(timerInterval: Self.recordingRange(context.state.startedAt), countsDown: false)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if context.state.stage == .standby, let expiresAt = context.state.expiresAt {
                    Text(timerInterval: Date()...expiresAt, countsDown: true)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
            .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    // ⚠️ 灵动岛的**任何**区域都不要放自绘视图,展开态也不行。
                    // build 111 只退了紧凑态、展开态仍留着自绘的 BrandWaveform,真机上灵动岛
                    // 依然一片空白 —— 说明展开区渲染失败会把整张卡片一起拖垮,紧凑态跟着不显示。
                    // 品牌标识只放锁屏那个独立闭包(空间充足、与灵动岛互不影响)。
                    statusIcon(context.state.stage)
                        .foregroundStyle(statusColor(context.state.stage))
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(headline(context.state.stage))
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.stage == .recording {
                        Text(timerInterval: Self.recordingRange(context.state.startedAt), countsDown: false)
                            .font(.caption.monospacedDigit())
                            .frame(width: 52)
                    } else if context.state.stage == .standby, let expiresAt = context.state.expiresAt {
                        Text(timerInterval: Date()...expiresAt, countsDown: true)
                            .font(.caption.monospacedDigit())
                            .frame(width: 58)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        Text(context.state.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if context.state.stage == .standby {
                            Link(destination: URL(string: "voicepen://standby-stop")!) {
                                Label("结束待命", systemImage: "stop.circle")
                                    .font(.caption.bold())
                            }
                        }
                    }
                }
            } compactLeading: {
                // ⚠️ 紧凑态与 minimal **只用 SF Symbol**,不要换成自绘视图。
                // build 107 用 SF Symbol 时用户确认灵动岛正常显示;build 109 换成自绘的
                // BrandWaveform 后就一片空白 —— 灵动岛紧凑区的尺寸约束很紧,自绘视图容易
                // 被压成零尺寸,而且失败是静默的(不崩、不报错,就是不画)。品牌标识放在
                // 展开态和锁屏那两处有空间的地方,那里已验证可用。
                statusIcon(context.state.stage)
                    .foregroundStyle(statusColor(context.state.stage))
            } compactTrailing: {
                compactTrailing(context.state)
            } minimal: {
                statusIcon(context.state.stage)
                    .foregroundStyle(statusColor(context.state.stage))
            }
            .keylineTint(statusColor(context.state.stage))
        }
    }

    /// 录音计时器的区间上界必须**有界**。原来写的是 `Date.distantFuture`(公元 4001 年),
    /// 等于要求系统渲染一个约两千年的计时区间;真机上这一格渲染不出东西,灵动岛看着
    /// 就像"没显示"(2026-08-06 用户反馈)。4 小时足够覆盖任何一次口述,与
    /// `ActionCaptureSessionStore` 的遗留判定量级也一致。
    private static func recordingRange(_ start: Date) -> ClosedRange<Date> {
        start...start.addingTimeInterval(4 * 60 * 60)
    }

    @ViewBuilder
    private func compactTrailing(_ state: CaptureActivityAttributes.ContentState) -> some View {
        if state.stage == .recording {
            Text(timerInterval: Self.recordingRange(state.startedAt), countsDown: false)
                .font(.caption2.monospacedDigit())
                .frame(width: 42)
        } else if state.stage == .standby, let expiresAt = state.expiresAt {
            Text(timerInterval: Date()...expiresAt, countsDown: true)
                .font(.caption2.monospacedDigit())
                .frame(width: 48)
        } else {
            Text(shortTitle(state.stage)).font(.caption2.bold())
        }
    }

    /// 标题栏第一行。录音/启动/识别这些"进行中"的状态一律先报出品牌名 —— 用户的原话是
    /// "不知道是什么软件在录音"。只有终态(处理完成/未能完成)才让结果本身当标题,
    /// 那时候用户已经知道是谁在做事了,结果比署名重要。
    private func headline(_ stage: CaptureActivityAttributes.Stage) -> String {
        switch stage {
        case .starting, .standby, .recording, .processing:
            return "Shall We Talk"
        case .completed:
            return "处理完成"
        case .failed:
            return "未能完成"
        }
    }

    /// 进行中的状态用品牌波形(可辨认是哪个 App),终态用结果图标(对错一眼可辨)。
    /// 只用于展开态与锁屏 —— 那两处有足够空间,自绘的品牌波形能正常渲染。
    /// 紧凑态/minimal 见上面的注释:那里必须用 SF Symbol。
    @ViewBuilder
    private func brandOrStatusIcon(_ stage: CaptureActivityAttributes.Stage) -> some View {
        switch stage {
        case .starting, .standby, .recording, .processing:
            BrandWaveform(height: 20, tint: statusColor(stage))
        case .completed, .failed:
            statusIcon(stage)
                .font(.title2)
                .foregroundStyle(statusColor(stage))
        }
    }

    private func shortTitle(_ stage: CaptureActivityAttributes.Stage) -> String {
        switch stage {
        case .starting: return "启动"
        case .standby: return "待命"
        case .recording: return "录音"
        case .processing: return "识别"
        case .completed: return "完成"
        case .failed: return "失败"
        }
    }

    private func statusIcon(_ stage: CaptureActivityAttributes.Stage) -> Image {
        switch stage {
        case .starting: return Image(systemName: "mic")
        case .standby: return Image(systemName: "mic.badge.plus")
        case .recording: return Image(systemName: "waveform.circle.fill")
        case .processing: return Image(systemName: "text.magnifyingglass")
        case .completed: return Image(systemName: "checkmark.circle.fill")
        case .failed: return Image(systemName: "exclamationmark.circle.fill")
        }
    }

    private func statusColor(_ stage: CaptureActivityAttributes.Stage) -> Color {
        switch stage {
        case .starting, .processing: return .orange
        case .standby: return .cyan
        case .recording: return .red
        case .completed: return .green
        case .failed: return .yellow
        }
    }
}
