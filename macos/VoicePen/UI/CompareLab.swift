import AppKit
import SwiftUI

/// 单路引擎的对比结果
struct EngineResult {
    var label: String
    var text = ""
    var millis = 0          // 总耗时(识别:停止→终稿;整理:发起→完成)
    var ttftMillis: Int?    // 整理首字耗时
    var error: String?
}

/// 一次口述的完整对比数据
struct CompareRun {
    var date = Date()
    var asrA: EngineResult?
    var asrB: EngineResult?
    var cleanA: EngineResult?
    var cleanB: EngineResult?
}

/// 对比实验室窗口(代码控制,口述完成后自动弹出)
@MainActor
final class CompareLabWindowController {
    private let window: NSWindow

    init(appState: AppState) {
        let hosting = NSHostingView(rootView: CompareLabView().environmentObject(appState))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "对比实验室"
        window.contentView = hosting
        window.center()
        window.isReleasedWhenClosed = false
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct CompareLabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if let run = appState.compareRun {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("口述时间:\(run.date.formatted(date: .abbreviated, time: .standard))")
                            .font(.caption).foregroundStyle(Theme.textSecondary)

                        ComparisonSummary(run: run)

                        if run.asrA != nil || run.asrB != nil {
                            Text("语音识别").font(.headline).foregroundStyle(Theme.textPrimary)
                            HStack(alignment: .top, spacing: 12) {
                                if let a = run.asrA { ResultCardCompare(result: a) }
                                if let b = run.asrB { ResultCardCompare(result: b) }
                            }
                        }

                        if run.cleanA != nil || run.cleanB != nil {
                            Text("文字整理(各走各的识别稿)").font(.headline).foregroundStyle(Theme.textPrimary)
                            HStack(alignment: .top, spacing: 12) {
                                if let a = run.cleanA { ResultCardCompare(result: a) }
                                if let b = run.cleanB { ResultCardCompare(result: b) }
                            }
                        }
                    }
                    .padding(16)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "scalemass").font(.system(size: 30)).foregroundStyle(Theme.accent)
                    Text("对比模式已开启").foregroundStyle(Theme.textPrimary)
                    Text("说一段话,识别与整理的 A/B 结果和耗时会显示在这里。")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 480)
    }
}

struct ComparisonSummary: View {
    let run: CompareRun

    var body: some View {
        let lines = summaryLines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("速度摘要", systemImage: "speedometer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Text("质量仍需人工判断:优先看是否忠实、不加内容、少删信息,其次看表达密度。")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary.opacity(0.9))
            }
            .padding(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 0.5))
        }
    }

    private var summaryLines: [String] {
        var out: [String] = []
        if let line = speedLine(title: "识别", firstName: "首段",
                                a: run.asrA, b: run.asrB) {
            out.append(line)
        }
        if let line = speedLine(title: "整理", firstName: "首字",
                                a: run.cleanA, b: run.cleanB) {
            out.append(line)
        }
        return out
    }

    private func speedLine(title: String, firstName: String,
                           a: EngineResult?, b: EngineResult?) -> String? {
        guard let a, let b, a.error == nil, b.error == nil else { return nil }
        var parts: [String] = []
        if let af = a.ttftMillis, let bf = b.ttftMillis {
            parts.append("\(firstName)\(winner(a: af, b: bf))")
        }
        parts.append("总耗时\(winner(a: a.millis, b: b.millis))")
        return "\(title):" + parts.joined(separator: "；")
    }

    private func winner(a: Int, b: Int) -> String {
        if a == b { return "A/B 持平(\(a)ms)" }
        if a < b { return "A 快 \(b - a)ms(A \(a)ms / B \(b)ms)" }
        return "B 快 \(a - b)ms(A \(a)ms / B \(b)ms)"
    }
}

struct ResultCardCompare: View {
    let result: EngineResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(result.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Spacer()
                if let ttft = result.ttftMillis {
                    Text("\(firstMetricName) \(ttft)ms")
                        .font(.caption2.monospaced()).foregroundStyle(Theme.textSecondary)
                }
                if result.error == nil {
                    Text("\(result.text.count)字")
                        .font(.caption2.monospaced()).foregroundStyle(Theme.textSecondary)
                }
                Text("总 \(result.millis)ms")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            if let err = result.error {
                ScrollView {
                    Text(err).font(.caption).foregroundStyle(Theme.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 60, maxHeight: 170)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(err, forType: .string)
                } label: {
                    Label("复制错误", systemImage: "doc.on.doc").font(.caption)
                }
            } else {
                ScrollView {
                    Text(result.text)
                        .font(.callout)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 80, maxHeight: 200)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.text, forType: .string)
                } label: {
                    Label("复制这版", systemImage: "doc.on.doc")
                        .font(.caption)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 0.5))
    }

    private var firstMetricName: String {
        result.label.hasPrefix("识别") ? "首段" : "首字"
    }
}
