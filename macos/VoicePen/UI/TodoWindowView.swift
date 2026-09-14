import SwiftUI

/// 闪念待办窗口(设计包 §Screens.5):最小 340×420,canvas 底,标题栏同历史窗口 + 「口述新待办」
/// accent 胶囊。单张 card 列表卡 r18;勾选圈 19pt;完成态划线;hover 行 ink@3% + 浮现 ✕。
struct TodoWindowView: View {
    @EnvironmentObject var appState: AppState
    @State private var showCompleted = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if appState.todos.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        section(title: "待办 · \(appState.todos.pendingCount)") {
                            listCard {
                                ForEach(Array(appState.todos.pending.enumerated()), id: \.element.id) { i, item in
                                    if i > 0 { rowDivider }
                                    TodoRow(item: item)
                                }
                            }
                        }

                        if !appState.todos.completed.isEmpty {
                            section(title: "已完成 · \(appState.todos.completed.count)", collapsible: true) {
                                listCard {
                                    ForEach(Array(appState.todos.completed.enumerated()), id: \.element.id) { i, item in
                                        if i > 0 { rowDivider }
                                        TodoRow(item: item)
                                    }
                                    rowDivider
                                    Button("清除已完成") { appState.todos.clearCompleted() }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.danger)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                }
                            }
                        }

                        Text("以「提醒我 / 记一下 / 待办」开头口述,自动进入这里。")
                            .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .padding(Space.windowMarginLG)
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if let error = appState.todos.persistenceError {
                HStack {
                    Text(error).font(.caption)
                    Button("重试保存") { appState.todos.retryPersistence() }
                }.padding()
            }
        }
        .frame(minWidth: 340, minHeight: 420)
        .navigationTitle("闪念待办")
        .toolbar {
            ToolbarItem {
                Button {
                    appState.toggle()
                } label: {
                    HStack(spacing: 6) {
                        StaticWaveformTicks(count: 3, color: .white, tickWidth: 2, spacing: 2,
                                            heights: [6, 10, 7])
                        Text("口述新待办").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.pressable)
                .help("以「提醒我 / 记一下 / 待办」开头口述,自动进入这里")
            }
        }
        .quietWindowChrome()
    }

    @ViewBuilder
    private func section<Content: View>(title: String, collapsible: Bool = false,
                                        @ViewBuilder content: () -> Content) -> some View {
        let inner = content()
        if collapsible {
            DisclosureGroup(isExpanded: $showCompleted) {
                inner.padding(.top, 6)
            } label: {
                Text(title).quietSectionLabel()
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).quietSectionLabel()
                inner
            }
        }
    }

    private func listCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .cardSurface(radius: Radius.card)
    }

    private var rowDivider: some View {
        Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 30)
    }

    private var emptyState: some View {
        VStack(spacing: Space.sm) {
            SoundTraceGlyph(diameter: 34, color: Theme.accent)
            Text("闪念待办")
                .quietTitle2()
                .foregroundStyle(Theme.textPrimary)
            Text("任何时候按下口述快捷键,以\n「提醒我…」「记一下…」「待办…」开头说话,\n事项会自动整理并出现在这里。")
                .quietFootnote()
                .multilineTextAlignment(.center)
        }
    }
}

/// 行高 44,勾选圈 19pt/1.8pt ink@25% 描边;完成 = accent 实心圆 + 白勾,文字划线 + ink@40%;
/// hover 行 ink@3% + 右侧浮现 ✕(14pt ink@20% 圆底)
struct TodoRow: View {
    @EnvironmentObject var appState: AppState
    let item: TodoItem
    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @State private var refining = false
    @State private var failure: String?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(Motion.snappy) {
                    appState.todos.toggle(item.id)
                }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(Theme.textPrimary.opacity(0.25), lineWidth: 1.8)
                        .background(Circle().fill(item.done ? Theme.accent : .clear))
                        .frame(width: 19, height: 19)
                    if item.done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .quietBody()
                    .fixedSize(horizontal: false, vertical: true)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? Theme.textPrimary.opacity(0.4) : Theme.textPrimary)
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer()

            if hovering {
                Button {
                    appState.todos.delete(item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textPrimary.opacity(0.6))
                        .frame(width: 14, height: 14)
                        .background(Theme.textPrimary.opacity(0.2), in: Circle())
                }
                .buttonStyle(.plain)
                .help("删除")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .background(hovering ? Theme.textPrimary.opacity(0.03) : .clear)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .contextMenu {
            Button("编辑…") { draft = item.text; editing = true }
            Button(refining ? "正在重新整理…" : "重新整理这次口述的待办") {
                refining = true
                Task {
                    defer { refining = false }
                    do { try await appState.refineTodo(item) }
                    catch { failure = error.localizedDescription }
                }
            }.disabled(refining)
            if let sourceID = item.sourceRecordID,
               let record = appState.history.records.first(where: { $0.id == sourceID }),
               let audio = appState.history.audioURL(for: record) {
                Button("播放原音") { NSWorkspace.shared.open(audio) }
            }
        }
        .sheet(isPresented: $editing) {
            VStack(spacing: 14) {
                Text("编辑待办").font(.headline)
                TextEditor(text: $draft).frame(width: 400, height: 140)
                HStack {
                    Button("取消") { editing = false }
                    Spacer()
                    Button("保存") { appState.updateTodoText(item.id, text: draft); editing = false }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20)
        }
        .alert("重新整理未完成", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好") { failure = nil }
            } message: { Text(failure ?? "") }
    }
}
