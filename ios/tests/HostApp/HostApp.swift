import UIKit

@main
final class HostAppDelegate: UIResponder, UIApplicationDelegate {}

final class HostSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = HostViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

/// 专用验收宿主。它不链接 VoicePen 键盘代码；文本只能经过 iOS 的
/// UIInputViewController -> UITextDocumentProxy 路径进入这些标准 UIKit 输入控件。
final class HostViewController: UIViewController, UITextViewDelegate, UITextFieldDelegate {
    private let textView = UITextView()
    private let textField = UITextField()
    private let searchField = UISearchTextField()
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let title = UILabel()
        title.text = "VoicePen 真实宿主验收"
        title.font = .preferredFont(forTextStyle: .title2)

        textView.font = .preferredFont(forTextStyle: .body)
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.layer.borderWidth = 1
        textView.layer.cornerRadius = 10
        textView.accessibilityIdentifier = "host.textView"
        textView.delegate = self
        textView.heightAnchor.constraint(equalToConstant: 180).isActive = true

        textField.borderStyle = .roundedRect
        textField.placeholder = "UITextField"
        textField.accessibilityIdentifier = "host.textField"
        textField.delegate = self

        searchField.placeholder = "UISearchTextField"
        searchField.accessibilityIdentifier = "host.searchField"
        searchField.delegate = self

        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2
        statusLabel.accessibilityIdentifier = "host.status"

        let controls = UIStackView(arrangedSubviews: [
            button("空文本", id: "scenario.empty", action: #selector(emptyScenario)),
            button("光标中间", id: "scenario.middle", action: #selector(middleScenario)),
            button("多行", id: "scenario.multiline", action: #selector(multilineScenario))
        ])
        controls.axis = .horizontal
        controls.spacing = 8
        controls.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [title, controls, textView, textField, searchField, statusLabel])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18)
        ])
        scheduleInjectedDeliveriesIfRequested()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // UITextField 会在真正挂进可见 window 时重设 selection。等到这里再
        // 聚焦和设置光标，验收的中间插入位置才是宿主实际交给键盘的状态。
        configureInitialScenario()
    }

    private func button(_ title: String, id: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.accessibilityIdentifier = id
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func emptyScenario() {
        textView.text = ""
        focusTextView(atUTF16Offset: 0, name: "empty")
    }

    @objc private func middleScenario() {
        textView.text = "前缀【已有文本】后缀"
        focusTextView(atUTF16Offset: ("前缀【已有文本】" as NSString).length, name: "middle")
    }

    @objc private func multilineScenario() {
        textView.text = "第一行\n第三行"
        focusTextView(atUTF16Offset: ("第一行\n" as NSString).length, name: "multiline")
    }

    private func textFieldScenario() {
        focusTextField(
            textField,
            text: "单行前缀单行后缀",
            atUTF16Offset: ("单行前缀" as NSString).length,
            name: "textField"
        )
    }

    private func searchFieldScenario() {
        focusTextField(
            searchField,
            text: "搜索前缀搜索后缀",
            atUTF16Offset: ("搜索前缀" as NSString).length,
            name: "searchField"
        )
    }

    private func focusTextView(atUTF16Offset offset: Int, name: String) {
        textView.becomeFirstResponder()
        textView.selectedRange = NSRange(location: offset, length: 0)
        statusLabel.text = "scenario=\(name) length=\((textView.text as NSString).length) cursor=\(offset)"
    }

    private func focusTextField(
        _ field: UITextField,
        text: String,
        atUTF16Offset offset: Int,
        name: String
    ) {
        field.text = text
        field.becomeFirstResponder()
        if let position = field.position(from: field.beginningOfDocument, offset: offset) {
            field.selectedTextRange = field.textRange(from: position, to: position)
        }
        statusLabel.text = "scenario=\(name) length=\((text as NSString).length) cursor=\(offset)"
    }

    func textViewDidChange(_ textView: UITextView) {
        statusLabel.text = "changed length=\((textView.text as NSString).length) cursor=\(textView.selectedRange.location)"
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    private func configureInitialScenario() {
        switch argument(after: "--voicepen-host-scenario") {
        case "middle": middleScenario()
        case "multiline": multilineScenario()
        case "textField": textFieldScenario()
        case "searchField": searchFieldScenario()
        default: emptyScenario()
        }
    }

    /// UI 测试不直接链接或调用键盘扩展。宿主仅作为第二个持有同一
    /// App Group 权限的开发 App，模拟“主 App 已识别完成”并发布 payload。
    /// 真正的插入仍只能由系统运行中的 VoicePen 键盘进程完成。
    private func scheduleInjectedDeliveriesIfRequested() {
        guard let encoded = argument(after: "--voicepen-host-payloads"),
              let data = Data(base64Encoded: encoded),
              let payloads = try? JSONDecoder().decode([String].self, from: data),
              !payloads.isEmpty else { return }

        for (index, text) in payloads.enumerated() {
            // 先让 UI 测试确认系统已经把 Shall We Talk 键盘挂到输入框，
            // 再发布结果；否则宿主场景初始化可能在插入后把文本重置。
            DispatchQueue.main.asyncAfter(deadline: .now() + 4 + Double(index) * 1.5) { [weak self] in
                let requestID = "record:host:\(index):\(UUID().uuidString)"
                KeyboardBridgeStore.publish { snapshot in
                    snapshot.phase = .ready
                    snapshot.requestID = requestID
                    snapshot.handledRequestID = requestID
                    snapshot.resultRequestID = requestID
                    snapshot.finalText = text
                }
                let published = PendingTextStore.push(text, requestID: requestID)
                self?.statusLabel.text = published
                    ? "published index=\(index) length=\((text as NSString).length)"
                    : "publish-failed index=\(index)"
            }
        }
    }

    private func argument(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
