import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ShallWeTalkCore

/// 生词词典管理窗口:把此前设置页「词典」分页里的简陋文本框列表升级为宽敞的卡片式界面,
/// 交互对齐 iOS `DictionarySettingsPage`(新增/点选卡片进入行内编辑/删除),视觉走
/// Quiet Ink 既有 token(cardSurface/quietSectionLabel/hoverHighlight 等),不新造颜色字体。
///
/// 信息架构选择:独立窗口而非设置内子页——设置窗口固定 560×480(见 SettingsView 头部注释),
/// 装不下"宽敞卡片网格"的定稿要求;History/闪念待办已经是"按钮从设置/菜单打开独立窗口"的
/// macOS 惯例(本窗口与它们同构:声明式 Window scene + quietWindowChrome),CompareLab/
/// BatchBench 也是从设置页按钮跳出的独立窗口先例。设置页「词典」分页保留一个精简统计入口。
///
/// 数据层不变:手动/自动词区分展示沿用 macOS 已有的 manualDictionaryWords/autoDictionaryWords
/// 两个分区(iOS 版本身把两者合并成一个列表展示,这里保留更清晰的区分,不算偏离——用户需求
/// 明确要求这个区分);写入一律走 SettingsStore.addDictionaryWord/updateDictionaryWord/
/// deleteDictionaryWord/blockAutoWord 这几个既有方法,保证 DictionarySyncCoordinator 后续
/// 同步时墓碑(tombstone)正确生成。
///
/// 替换词组(手动纠错对,2026-08-17 起补上用户可见的增删入口):与自动挖掘的纠错对共用
/// SettingsStore.manualCorrections + effectiveCorrections 管线,额外经 ManualCorrections.apply
/// 做一遍确定性、大小写不敏感的字符串替换兜底——纠错对本来只喂给整理 prompt,是否严格执行、
/// 是否分大小写全靠模型,不保证生效,这里加一道代码层保证。
struct DictionaryWindowView: View {
    @EnvironmentObject var appState: AppState
    @State private var newWord = ""
    @State private var editingWord: String?
    @State private var editingDraft = ""
    @State private var correctionSource = ""
    @State private var correctionTarget = ""
    @State private var editingCorrectionSource: String?
    @State private var editingCorrectionSourceDraft = ""
    @State private var editingCorrectionTargetDraft = ""

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: Space.sm)]

    /// 手动、本机学习和云端同步来的纠错对统一呈现。删除必须走 SettingsStore 的 blocklist
    /// 路径，不能只删手动项，否则下一轮历史扫描会把同一 source 重新挖出来。
    private var allCorrections: [LearnedCorrection] {
        DictionarySyncCoordinator.effectiveCorrections(
            records: appState.history.records, manual: appState.settings.manualCorrections,
            blocked: appState.settings.blockedCorrectionSources)
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    HStack {
                        if appState.dictionarySyncRunning { ProgressView().controlSize(.small) }
                        Text(appState.lastDictionarySyncStatus)
                        if let date = appState.lastDictionarySyncDate {
                            Text("上次成功：" + date.formatted(date: .abbreviated, time: .shortened))
                        }
                    }.font(.caption).foregroundStyle(Theme.textSecondary)
                    addWordRow

                    section(title: "个人词典 · \(appState.settings.manualDictionaryWords.count)") {
                        if appState.settings.manualDictionaryWords.isEmpty {
                            emptyHint("还没有手动添加的词。人名、机构、专有名词等易被识别错的词,加进来后识别与整理都会统一采用这个写法。")
                        } else {
                            LazyVGrid(columns: columns, spacing: Space.sm) {
                                ForEach(appState.settings.manualDictionaryWords, id: \.self) { word in
                                    wordCard(word, isAuto: false)
                                }
                            }
                        }
                    }

                    section(title: "自动学习的词 · \(appState.settings.autoDictionaryWords.count)") {
                        if appState.settings.autoDictionaryWords.isEmpty {
                            emptyHint("暂无。日常使用中,反复出现的英文/专有词(≥3 次)和反复做过的同一修正(≥2 次)会自动加入这里,无需手动维护。")
                        } else {
                            LazyVGrid(columns: columns, spacing: Space.sm) {
                                ForEach(appState.settings.autoDictionaryWords, id: \.self) { word in
                                    wordCard(word, isAuto: true)
                                }
                            }
                        }
                    }

                    addCorrectionRow

                    section(title: "纠错对 · \(allCorrections.count)") {
                        if allCorrections.isEmpty {
                            emptyHint("识别常错的固定搭配,填「识别成什么」→「该写成什么」。手动、自动学习和其它设备同步来的纠错对统一在此管理。")
                        } else {
                            VStack(spacing: Space.sm) {
                                ForEach(allCorrections, id: \.source) { pair in
                                    correctionRow(pair)
                                }
                            }
                        }
                    }
                }
                .padding(Space.windowMarginLG)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .navigationTitle("生词词典")
        .toolbar {
            ToolbarItem {
                Button("载入中英混热词包") {
                    appState.settings.loadMixedTermPack()
                    appState.scheduleDictionarySync(reason: "词典编辑")
                }
                .buttonStyle(.quietStroke)
                .help("一键把国内职场/科技/日常最常混说、ASR 最易听错的英文词加进词典(\(SettingsStore.mixedTermPack.count) 个,已存在的不重复)")
            }
            ToolbarItem {
                Button("导入…", action: importWords)
                    .buttonStyle(.quietStroke)
                    .help("从文本文件(每行一词)或 JSON 文件导入词典条目,已存在的不重复")
            }
            ToolbarItem {
                Button("导出…", action: exportWords)
                    .buttonStyle(.quietStroke)
                    .help("把词条、纠错对和屏蔽项导出为 JSON 文件,供备份或导入其它设备")
            }
            ToolbarItem {
                Button("立即同步") { appState.syncDictionaryNow() }
                    .buttonStyle(.quietStroke)
                    .help("跳过 5 秒防抖,马上把本机词典(含刚做的删除)与 iCloud 合并——" +
                          appState.lastDictionarySyncStatus)
            }
        }
        .quietWindowChrome()
    }

    // MARK: - 顶部添加行

    private var addWordRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
            TextField("输入人名、机构或专有名词,回车添加", text: $newWord)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit(addWord)
            Button("添加", action: addWord)
                .buttonStyle(.quietSolid)
                .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .cardSurface(radius: Radius.card)
    }

    // MARK: - 替换词组:添加行 + 展示行

    private var addCorrectionRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
            TextField("识别成什么(不分大小写)", text: $correctionSource)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
            Image(systemName: "arrow.right")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            TextField("该写成什么", text: $correctionTarget)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit(addCorrection)
            Button("添加", action: addCorrection)
                .buttonStyle(.quietSolid)
                .disabled(correctionSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || correctionTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .cardSurface(radius: Radius.card)
    }

    private func correctionRow(_ pair: LearnedCorrection) -> some View {
        if editingCorrectionSource == pair.source {
            return AnyView(correctionEditRow(pair))
        }
        return AnyView(HStack(spacing: 10) {
            Button {
                editingCorrectionSource = pair.source
                editingCorrectionSourceDraft = pair.source
                editingCorrectionTargetDraft = pair.target
            } label: {
                HStack(spacing: 10) {
                    Text(pair.source)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                    Text(pair.target)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            Button {
                appState.settings.deleteCorrection(source: pair.source)
                appState.scheduleDictionarySync(reason: "删除纠错对")
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("删除并阻止再次学习")
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .cardSurface(radius: Radius.card))
    }

    private func correctionEditRow(_ pair: LearnedCorrection) -> some View {
        HStack(spacing: 10) {
            TextField("识别成什么", text: $editingCorrectionSourceDraft)
                .textFieldStyle(.roundedBorder)
            Image(systemName: "arrow.right")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            TextField("该写成什么", text: $editingCorrectionTargetDraft)
                .textFieldStyle(.roundedBorder)
            Spacer()
            Button {
                let source = editingCorrectionSourceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                let target = editingCorrectionTargetDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard appState.settings.addManualCorrection(source: source, target: target) else { return }
                if source.caseInsensitiveCompare(pair.source) != .orderedSame {
                    appState.settings.deleteCorrection(source: pair.source)
                }
                editingCorrectionSource = nil
                appState.scheduleDictionarySync(reason: "纠错对手动修正")
            } label: {
                Text("保存").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.quietSolid)
            Button("取消") { editingCorrectionSource = nil }
                .buttonStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .cardSurface(radius: Radius.card)
    }

    private func addCorrection() {
        guard appState.settings.addManualCorrection(source: correctionSource, target: correctionTarget) else { return }
        correctionSource = ""
        correctionTarget = ""
        appState.scheduleDictionarySync(reason: "词典编辑")
    }

    // MARK: - 分区

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).quietSectionLabel()
            content()
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .quietFootnote()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(radius: Radius.card)
    }

    // MARK: - 词卡(展示态 / 行内编辑态)

    @ViewBuilder
    private func wordCard(_ word: String, isAuto: Bool) -> some View {
        if editingWord == word {
            editCard(word)
        } else {
            DictionaryWordCard(word: word, isAuto: isAuto) {
                editingWord = word
                editingDraft = word
            } onRemove: {
                remove(word, isAuto: isAuto)
            }
        }
    }

    private func editCard(_ word: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("热词", text: $editingDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, weight: .medium))
                .onSubmit { saveEdit(word) }
            HStack(spacing: 8) {
                Button {
                    appState.settings.deleteDictionaryWord(word)
                    editingWord = nil
                    appState.scheduleDictionarySync(reason: "词典编辑")
                } label: {
                    Text("删除")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.danger)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                Spacer()
                Button("取消") { editingWord = nil }
                    .buttonStyle(.quietStroke)
                Button("保存") { saveEdit(word) }
                    .buttonStyle(.quietSolid)
                    .disabled(editingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .cardSurface(radius: Radius.card)
    }

    // MARK: - 写入(一律走 SettingsStore 既有方法,保证同步墓碑正确生成)

    private func addWord() {
        guard appState.settings.addDictionaryWord(newWord) else { return }
        newWord = ""
        appState.scheduleDictionarySync(reason: "词典编辑")
    }

    private func saveEdit(_ oldWord: String) {
        guard appState.settings.updateDictionaryWord(oldWord, to: editingDraft) else { return }
        editingWord = nil
        appState.scheduleDictionarySync(reason: "词典编辑")
    }

    private func remove(_ word: String, isAuto: Bool) {
        if isAuto {
            appState.settings.blockAutoWord(word)
        } else {
            appState.settings.deleteDictionaryWord(word)
        }
        appState.scheduleDictionarySync(reason: "词典编辑")
    }

    // MARK: - 导入 / 导出(JSON: {"manual":[...],"auto":[...]}, 兼容纯文本每行一词 / 扁平 JSON 数组)

    /// NSOpenPanel/NSSavePanel 记住上次目录,与 HistoryWindowView.exportDirectoryKey 同一模式
    private static let ioDirectoryKey = "dictionaryImportExportDirectoryPath"

    private func importWords() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText]
        panel.allowsMultipleSelection = false
        if let path = UserDefaults.standard.string(forKey: Self.ioDirectoryKey) {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let backup = try DictionaryBackup.parse(Data(contentsOf: url), isJSON: url.pathExtension.lowercased() == "json")
            let alert = NSAlert()
            alert.messageText = "确认合并词典备份"
            alert.informativeText = backup.preview(mergingInto: appState.dictionaryBackup).message
            alert.addButton(withTitle: "合并导入")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            _ = appState.importDictionaryBackup(backup)
            UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: Self.ioDirectoryKey)
        } catch { NSAlert(error: error).runModal() }
    }

    private func exportWords() {
        let file = appState.dictionaryBackup
        guard let data = try? JSONEncoder.prettyPrinted.encode(file) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "shall-we-talk-dictionary.json"
        if let path = UserDefaults.standard.string(forKey: Self.ioDirectoryKey) {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch { NSAlert(error: error).runModal(); return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: Self.ioDirectoryKey)
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

/// 展示态词卡:52pt 行高(比 iOS 48pt 版式更宽裕的鼠标点击目标)、hover 时浮现铅笔提示 +
/// 移除按钮(macOS 鼠标惯例——常态不铺满图标,悬停才显露次要操作,同 TodoWindowView.TodoRow)。
/// 整卡可点(onTapGesture)进入行内编辑,移除按钮是独立 Button,不嵌套在外层 Button 里。
private struct DictionaryWordCard: View {
    let word: String
    let isAuto: Bool
    var onTap: () -> Void
    var onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isAuto ? "sparkles" : "sparkle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(word)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if hovering {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(isAuto ? "移除并不再自动加入" : "删除")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .contentShape(Rectangle())
        .cardSurface(radius: Radius.card)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(hovering ? Theme.accent.opacity(0.25) : .clear, lineWidth: 1)
        )
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}
