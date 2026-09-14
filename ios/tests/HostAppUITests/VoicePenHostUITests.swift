import XCTest

final class VoicePenHostUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 专用模拟器的一次性前置。独立运行该测试后，再跑宿主矩阵。
    /// 真机上仍建议由人手工确认系统弹窗的数据访问提示。
    func test00EnableVoicePenFullAccess() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        try tap("General", in: settings)
        try tap("Keyboard", in: settings)
        try tap("Keyboards", in: settings)
        if !settings.staticTexts["Shall We Talk"].waitForExistence(timeout: 2) {
            try tapFirstAvailable(
                ["Add New Keyboard", "Add New Keyboard...", "Add New Keyboard…", "添加新键盘", "添加新键盘…"],
                in: settings
            )
            try tap("Shall We Talk", in: settings)
        }
        try tap("Shall We Talk", in: settings)

        let fullAccess = settings.switches["Allow Full Access"]
        guard fullAccess.waitForExistence(timeout: 5) else {
            throw HostMatrixError.preconditionFailed("Allow Full Access switch was not found")
        }
        if (fullAccess.value as? String) != "1" {
            // Settings 将整行暴露为 Switch，普通 tap() 会点到行中心而不是
            // x=305...368 的真实 UISwitch。显式点右侧开关区才会改变权限值。
            fullAccess.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()
            let settingsConfirm = settings.alerts.buttons["Allow"]
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let springboardConfirm = springboard.alerts.buttons["Allow"]
            if settingsConfirm.waitForExistence(timeout: 3) {
                settingsConfirm.tap()
            } else if springboardConfirm.waitForExistence(timeout: 1) {
                springboardConfirm.tap()
            } else {
                throw HostMatrixError.preconditionFailed(
                    "Full Access confirmation alert was not found"
                )
            }
        }
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == '1'"),
            object: fullAccess
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 3), .completed)
    }

    func testEmptyUITextView() throws {
        let payload = "一次完整的语音回填🎙️"
        try launchHost(scenario: "empty", payloads: [payload])
        try waitForText(payload)
    }

    func testMiddleCursorPreservesSurroundingText() throws {
        try launchHost(scenario: "middle", payloads: ["【插入】"])
        try waitForText("前缀【已有文本】【插入】后缀")
    }

    func testLongUnicodeMultilinePayload() throws {
        let payload = String(repeating: "中👨‍👩‍👧‍👦é\n", count: 256)
        try launchHost(scenario: "multiline", payloads: [payload])
        try waitForText("第一行\n\(payload)第三行", timeout: 10)
    }

    func testRapidBackToBackResultsRemainDistinct() throws {
        try launchHost(scenario: "empty", payloads: ["第一段", "第二段"])
        try waitForText("第一段第二段", timeout: 8)
    }

    func testUITextFieldMiddleCursor() throws {
        try launchHost(scenario: "textField", payloads: ["【插入】"])
        try waitForText(
            "单行前缀【插入】单行后缀",
            in: app.textFields["host.textField"]
        )
    }

    func testUISearchTextFieldMiddleCursor() throws {
        try launchHost(scenario: "searchField", payloads: ["【搜索词】"])
        try waitForText(
            "搜索前缀【搜索词】搜索后缀",
            in: app.descendants(matching: .any)["host.searchField"]
        )
    }

    func testTextFaceShowsAllThreeLetterRows() throws {
        try launchHost(scenario: "empty", payloads: [])

        let switchButton = app.buttons["切换到键盘模式"]
        XCTAssertTrue(switchButton.waitForExistence(timeout: 2))
        switchButton.tap()

        // 该测试只验证既有 26 键三排几何；布局偏好会跨测试持久化，先显式回到 26 键。
        let layoutToggle = app.buttons["keyboard.layout.toggle"]
        XCTAssertTrue(layoutToggle.waitForExistence(timeout: 2))
        if layoutToggle.label == "切换到二十六键拼音" {
            layoutToggle.tap()
        }

        // 分别取三排的按键作为布局哨兵；若外层高度被语音面压住、或切换键盖住
        // 第一排，至少会有一排按键无法出现在宿主可访问层级中。
        for key in ["q", "a", "z", "m"] {
            XCTAssertTrue(
                app.buttons[key].waitForExistence(timeout: 2),
                "文字键盘缺少按键：\(key)"
            )
        }
    }

    func testNineKeySwitchInputInitialsAndPersistence() throws {
        try launchHost(scenario: "empty", payloads: [])
        try switchToTextFace()

        let layoutToggle = app.buttons["keyboard.layout.toggle"]
        XCTAssertTrue(layoutToggle.waitForExistence(timeout: 2))
        if layoutToggle.label == "切换到九宫格拼音" {
            layoutToggle.tap()
        }

        let key2 = app.buttons["t9.2"]
        XCTAssertTrue(key2.waitForExistence(timeout: 2))
        try waitUntilEnabled(key2, timeout: 5)
        for digit in ["6", "4", "4", "2", "6"] {
            app.buttons["t9.\(digit)"].tap()
        }
        let hello = app.buttons["你好"]
        XCTAssertTrue(hello.waitForExistence(timeout: 3), "64426 应召回你好")
        hello.tap()
        try waitForText("你好")

        XCTAssertEqual(layoutToggle.label, "切换到二十六键拼音")
        layoutToggle.tap()
        let x = app.buttons["x"]
        XCTAssertTrue(x.waitForExistence(timeout: 2))
        try waitUntilEnabled(x, timeout: 5)
        x.tap()
        x.tap()
        let thanks = app.buttons["谢谢"]
        XCTAssertTrue(thanks.waitForExistence(timeout: 3), "xx 前六应包含谢谢")
        thanks.tap()
        try waitForText("你好谢谢")

        // 一次实际选择会立即重注入个人词；同一键盘会话再次输入 xx 后，空格首选即为谢谢。
        x.tap()
        x.tap()
        let learnedThanks = app.buttons["谢谢"]
        XCTAssertTrue(learnedThanks.waitForExistence(timeout: 3))
        learnedThanks.tap()
        try waitForText("你好谢谢谢谢")

        // 再切回九键并重启宿主，验证扩展重建后仍恢复最后选择。
        layoutToggle.tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textViews["host.textView"].waitForExistence(timeout: 5))
        try requireVoicePenKeyboard()
        try switchToTextFace()
        let restoredToggle = app.buttons["keyboard.layout.toggle"]
        XCTAssertTrue(restoredToggle.waitForExistence(timeout: 2))
        XCTAssertEqual(restoredToggle.label, "切换到二十六键拼音")
        XCTAssertTrue(app.buttons["t9.2"].waitForExistence(timeout: 2))

        // 英文始终回到 26 键；切回中文后恢复九键。
        app.buttons["keyboard.language.toggle"].tap()
        XCTAssertTrue(app.buttons["q"].waitForExistence(timeout: 2))
        XCTAssertFalse(restoredToggle.isEnabled)
        app.buttons["keyboard.language.toggle"].tap()
        XCTAssertTrue(app.buttons["t9.2"].waitForExistence(timeout: 2))
        XCTAssertTrue(restoredToggle.isEnabled)
    }

    func testNineKeyRapidLayoutSwitching100Times() throws {
        try launchHost(scenario: "empty", payloads: [])
        try switchToTextFace()

        let layoutToggle = app.buttons["keyboard.layout.toggle"]
        XCTAssertTrue(layoutToggle.waitForExistence(timeout: 2))
        let initialLabel = layoutToggle.label
        for index in 1...100 {
            layoutToggle.tap()
            if index.isMultiple(of: 10) {
                XCTAssertTrue(layoutToggle.exists, "第 \(index) 次布局切换后切换键消失")
            }
        }
        XCTAssertEqual(layoutToggle.label, initialLabel)
        if initialLabel == "切换到二十六键拼音" {
            XCTAssertTrue(app.buttons["t9.2"].waitForExistence(timeout: 2))
        } else {
            XCTAssertTrue(app.buttons["q"].waitForExistence(timeout: 2))
        }
    }

    /// 实际系统键盘扩展 -> 宿主marked text，确认选择前半段不会删掉未完成尾音。
    func testTextSelectionPreservesUnfinishedSyllable() throws {
        try launchHost(scenario: "empty", payloads: [])
        try switchToTextFace()
        let language = app.buttons["keyboard.language.toggle"]
        if language.label == "切换到中文" { language.tap() }
        let layout = app.buttons["keyboard.layout.toggle"]
        if layout.label == "切换到二十六键拼音" { layout.tap() }
        try waitUntilEnabled(app.buttons["n"], timeout: 5)
        for character in "nihaom" { app.buttons[String(character)].tap() }
        let hello = app.buttons["你好"]
        XCTAssertTrue(hello.waitForExistence(timeout: 3))
        hello.tap()
        try waitForText("你好m")
        for character in "ingtian" { app.buttons[String(character)].tap() }
        let tomorrow = app.buttons["明天"]
        XCTAssertTrue(tomorrow.waitForExistence(timeout: 3))
        tomorrow.tap()
        try waitForText("你好明天")
    }

    func testNineKeySelectionPreservesRemainder() throws {
        try launchHost(scenario: "empty", payloads: [])
        try switchToTextFace()
        let language = app.buttons["keyboard.language.toggle"]
        if language.label == "切换到中文" { language.tap() }
        let layout = app.buttons["keyboard.layout.toggle"]
        if layout.label == "切换到九宫格拼音" { layout.tap() }
        try waitUntilEnabled(app.buttons["t9.6"], timeout: 5)
        // wo'ming'tian：通过实际按钮输入分隔符，选词后保留后续分隔符。
        for character in "96'6464'8426" {
            app.buttons[character == "'" ? "t9.separator" : "t9.\(character)"].tap()
        }
        let me = app.buttons["我"]
        XCTAssertTrue(me.waitForExistence(timeout: 3))
        me.tap()
        try waitForText("我6464'8426")
        let tomorrow = app.buttons["明天"]
        XCTAssertTrue(tomorrow.waitForExistence(timeout: 3))
        tomorrow.tap()
        try waitForText("我明天")
    }

    /// 此词不在旧版50k核心集内，验证实际扩展确实使用新资源。
    func testExpandedIceVocabularyInHost() throws {
        try launchHost(scenario: "empty", payloads: [])
        try switchToTextFace()
        let language = app.buttons["keyboard.language.toggle"]
        if language.label == "切换到中文" { language.tap() }
        let layout = app.buttons["keyboard.layout.toggle"]
        if layout.label == "切换到二十六键拼音" { layout.tap() }
        try waitUntilEnabled(app.buttons["x"], timeout: 5)
        for character in "xinzhishengchanli" { app.buttons[String(character)].tap() }
        let word = app.buttons["新质生产力"]
        XCTAssertTrue(word.waitForExistence(timeout: 3))
        word.tap()
        try waitForText("新质生产力")
    }

    /// 点视觉键帽之外的键缝，必须实际上屏一次；不能只验证hitTest返回了按钮。
    func testLetterGapTouchesCommitOnce() throws {
        try launchHost(scenario: "empty", payloads: [])
        try switchToTextFace()
        let language = app.buttons["keyboard.language.toggle"]
        if language.label == "切换到英文" { language.tap() }
        let q = app.buttons["q"]
        let w = app.buttons["w"]
        XCTAssertTrue(q.waitForExistence(timeout: 3))
        XCTAssertEqual(language.label, "切换到中文")
        XCTAssertTrue(q.isEnabled)
        q.tap()
        try waitForText("q")
        app.buttons["scenario.empty"].tap()
        let horizontalGap = w.frame.minX - q.frame.maxX
        XCTAssertEqual(horizontalGap, 6, accuracy: 0.5)
        // 以宿主窗口为坐标锚，避免依赖扩展元素的相对窗口信息。
        // 屏幕几何仍取真实按键frame，并先验证中心坐标点击。
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        func at(_ point: CGPoint) -> XCUICoordinate {
            origin.withOffset(CGVector(dx: point.x - window.frame.minX,
                                       dy: point.y - window.frame.minY))
        }
        // 坐标通道本身也必须通过中心点击对照，不能把未交付事件算成键缝漏点。
        at(CGPoint(x: q.frame.midX, y: q.frame.midY)).tap()
        let coordinateControl = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 'q'"), object: app.textViews["host.textView"])
        guard XCTWaiter.wait(for: [coordinateControl], timeout: 3) == .completed else {
            throw HostMatrixError.preconditionFailed("Element tap succeeded but coordinate center tap did not reach keyboard")
        }
        app.buttons["scenario.empty"].tap()
        at(CGPoint(x: q.frame.maxX + horizontalGap * 0.25, y: q.frame.midY)).tap()
        at(CGPoint(x: w.frame.minX - horizontalGap * 0.25, y: w.frame.midY)).tap()
        try waitForText("qw")
        // 落下即提交；滑出不会取消已接受的一次按键。
        let inputFrame = app.textViews["host.textView"].frame
        at(CGPoint(x: q.frame.midX, y: q.frame.midY))
            .press(forDuration: 0.1, thenDragTo: at(CGPoint(x: inputFrame.midX, y: inputFrame.midY)))
        try waitForText("qwq")
        // 左外沿与首行上边缘仍归到q；不进入候选栏。
        at(CGPoint(x: q.frame.minX - 3, y: q.frame.midY)).tap()
        at(CGPoint(x: q.frame.midX, y: q.frame.minY - 3)).tap()
        try waitForText("qwqqq")
        q.doubleTap()
        try waitForText("qwqqqqq")
        app.buttons["keyboard.space"].tap(withNumberOfTaps: 1, numberOfTouches: 2)
        try waitForText("qwqqqqq  ")
        // 留回中文，避免改变其他测试的默认输入语言。
        language.tap()
    }

    private func launchHost(scenario: String, payloads: [String]) throws {
        app = XCUIApplication()
        let data = try JSONEncoder().encode(payloads)
        app.launchArguments += [
            "--voicepen-host-scenario", scenario,
            "--voicepen-host-payloads", data.base64EncodedString()
        ]
        app.launch()
        let activeControl: XCUIElement
        switch scenario {
        case "textField": activeControl = app.textFields["host.textField"]
        case "searchField": activeControl = app.descendants(matching: .any)["host.searchField"]
        default: activeControl = app.textViews["host.textView"]
        }
        XCTAssertTrue(activeControl.waitForExistence(timeout: 5))
        try requireVoicePenKeyboard()
    }

    private func switchToTextFace() throws {
        if app.buttons["keyboard.layout.toggle"].exists { return }
        let switchButton = app.buttons["切换到键盘模式"]
        guard switchButton.waitForExistence(timeout: 2) else {
            throw HostMatrixError.preconditionFailed("文字键盘切换键不存在")
        }
        switchButton.tap()
        guard app.buttons["keyboard.layout.toggle"].waitForExistence(timeout: 3) else {
            throw HostMatrixError.preconditionFailed("文字键盘底栏未出现")
        }
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: element
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            throw HostMatrixError.preconditionFailed("键盘词库在 \(timeout) 秒内没有就绪")
        }
    }

    private func waitForText(
        _ expected: String,
        in control: XCUIElement? = nil,
        timeout: TimeInterval = 6
    ) throws {
        let input = control ?? app.textViews["host.textView"]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expected),
            object: input
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        guard result == .completed else {
            XCTFail("expected \(expected.debugDescription), actual=\(String(describing: input.value))")
            return
        }
        XCTAssertEqual(input.value as? String, expected)
    }

    private func requireVoicePenKeyboard() throws {
        func isVoicePen() -> Bool {
            app.buttons["voice.record"].exists || app.buttons["keyboard.layout.toggle"].exists
        }
        if app.buttons["voice.record"].waitForExistence(timeout: 2) || isVoicePen() { return }

        // 先尝试系统键盘暴露的轮换按钮；不同语言/iOS 版本标签不同。
        let labels = ["Next keyboard", "下一个键盘", "切换到下一个键盘", "键盘"]
        // 快速点地球可能只在最近的两个键盘之间往返。长按后明确选择扩展，
        // 不把“已添加到系统列表”误当作“当前已切到该扩展”。
        if let label = labels.first(where: { app.buttons[$0].exists }) {
            app.buttons[label].press(forDuration: 0.8)
            let option = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "Shall We Talk")).firstMatch
            if option.waitForExistence(timeout: 2) {
                option.tap()
                if app.buttons["voice.record"].waitForExistence(timeout: 3) || isVoicePen() { return }
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
            }
        }
        for _ in 0..<8 {
            for label in labels where app.buttons[label].exists {
                app.buttons[label].tap()
                if app.buttons["voice.record"].waitForExistence(timeout: 1) || isVoicePen() { return }
            }
        }

        throw HostMatrixError.preconditionFailed(
            "Shall We Talk 系统键盘未启用，或未允许完全访问"
        )
    }

    private func tap(_ label: String, in application: XCUIApplication) throws {
        let cell = application.cells.containing(.staticText, identifier: label).firstMatch
        if cell.waitForExistence(timeout: 5) {
            cell.tap()
            return
        }
        let text = application.staticTexts[label]
        guard text.waitForExistence(timeout: 2) else {
            throw HostMatrixError.preconditionFailed("Settings row not found: \(label)")
        }
        text.tap()
    }

    private func tapFirstAvailable(
        _ labels: [String],
        in application: XCUIApplication
    ) throws {
        for label in labels {
            let element = application.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", label))
                .firstMatch
            if element.waitForExistence(timeout: 1) {
                element.tap()
                return
            }
        }
        throw HostMatrixError.preconditionFailed(
            "Settings row not found: \(labels.joined(separator: " / "))"
        )
    }
}

private enum HostMatrixError: Error {
    case preconditionFailed(String)
}
