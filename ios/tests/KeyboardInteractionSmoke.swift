import UIKit

/// 在iOS模拟器运行真实UIKit命中判定，不用手写几何替代UIKit。
/// 不模拟真实UITouch，也不把这些检查当作真机延迟/触觉验收。
private final class PressRecorder: NSObject {
    var output = ""
    @objc func record(_ sender: UIButton) { output += sender.accessibilityIdentifier ?? "?" }
}

@main
struct KeyboardInteractionSmoke {
    static func main() {
        var failures: [String] = []
        var checkedPoints = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        let field = KeyFieldStackView(frame: CGRect(x: 0, y: 0, width: 106, height: 101))
        field.axis = .vertical
        field.spacing = 11
        field.distribution = .fillEqually
        var buttons: [KeyFieldButton] = []
        for _ in 0..<2 {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 6
            row.distribution = .fillEqually
            for _ in 0..<2 {
                let button = KeyFieldButton(type: .system)
                row.addArrangedSubview(button)
                buttons.append(button)
            }
            field.addArrangedSubview(row)
        }
        field.layoutIfNeeded()
        check(buttons[0].bounds.width == 50 && buttons[0].bounds.height == 45, "Unexpected fixture geometry")

        // 包括横缝、行缝、交叉缝、中线、最外沿；不能同时属于两个键。
        for x in stride(from: CGFloat(0), to: 106, by: 0.5) {
            for y in stride(from: CGFloat(0), to: 101, by: 0.5) {
                let point = CGPoint(x: x, y: y)
                let owners = buttons.filter { $0.point(inside: field.convert(point, to: $0), with: nil) }
                check(owners.count == 1, "Point \(point) has \(owners.count) owners")
                check(field.hitTest(point, with: nil) === owners.first, "Hit/inside disagreement at \(point)")
                checkedPoints += 1
            }
        }
        for point in [CGPoint(x: -1, y: 22), CGPoint(x: 106, y: 22), CGPoint(x: 25, y: -1), CGPoint(x: 25, y: 101)] {
            check(!buttons.contains { $0.point(inside: field.convert(point, to: $0), with: nil) },
                  "Out-of-field point accepted: \(point)")
        }
        let gap = CGPoint(x: 52, y: 22)
        let owner = buttons[0]
        owner.isEnabled = false
        check(!owner.point(inside: field.convert(gap, to: owner), with: nil), "Disabled key accepts input")
        check(!(field.hitTest(gap, with: nil) is UIButton), "Disabled key gap redirects to another key")
        owner.isEnabled = true
        field.isUserInteractionEnabled = false
        check(field.hitTest(gap, with: nil) == nil, "Inactive page steals a touch")
        check(!owner.point(inside: field.convert(gap, to: owner), with: nil), "Inactive page remains inside")
        field.isUserInteractionEnabled = true
        field.isHidden = true
        check(field.hitTest(gap, with: nil) == nil, "Hidden page steals a touch")
        field.isHidden = false

        // 不伪造UITouch；直接检验生产事件分发器对独立触摸身份的处理。
        let recorder = PressRecorder()
        for (index, button) in buttons.enumerated() {
            button.accessibilityIdentifier = String(index)
            button.addAction(UIAction { _ in recorder.record(button) }, for: .primaryActionTriggered)
            check(button.isMultipleTouchEnabled && !button.isExclusiveTouch, "Multi-touch disabled")
        }
        let a = NSObject(), b = NSObject(), c = NSObject()
        buttons[0].beginPress(ObjectIdentifier(a))
        buttons[1].beginPress(ObjectIdentifier(b))
        buttons[0].beginPress(ObjectIdentifier(c)) // 同一个键上的重叠触摸
        buttons[0].beginPress(ObjectIdentifier(a)) // 同一触摸重复通知不能重复输入
        check(recorder.output == "010", "Overlapping down events lost/reordered: \(recorder.output)")
        buttons[0].endPress(ObjectIdentifier(c))
        buttons[1].endPress(ObjectIdentifier(b))
        buttons[0].endPress(ObjectIdentifier(a))
        check(recorder.output == "010", "Release double committed")
        for _ in 0..<1000 {
            buttons[0].beginPress(ObjectIdentifier(a))
            buttons[0].endPress(ObjectIdentifier(a))
        }
        check(recorder.output.count == 1003, "Fast repeated presses coalesced")
        check(buttons[1].accessibilityActivate(), "Accessibility activation failed")
        check(recorder.output.last == "1", "Accessibility activation lost")

        let root = KeyboardTouchInputView(frame: CGRect(x: 0, y: 0, width: 130, height: 150), inputViewStyle: .keyboard)
        root.addSubview(field)
        field.frame.origin = CGPoint(x: 12, y: 20)
        root.nearbyKey = { point in KeyboardTouchRouting.nearestKey(at: point, in: root, keys: buttons) }
        root.installTouchSurface()
        check(root.isMultipleTouchEnabled, "Root must accept overlapping touches")
        for point in [CGPoint(x: 30, y: 40), CGPoint(x: 64, y: 40), CGPoint(x: 0, y: 40)] {
            check(root.hitTest(point, with: nil) === root, "Keys and gaps must share the root touch receiver")
        }
        for point in [CGPoint(x: 0, y: 20), CGPoint(x: 129, y: 40),
                      CGPoint(x: 50, y: 12), CGPoint(x: 50, y: 149)] {
            check(KeyboardTouchRouting.nearestKey(at: point, in: root, keys: buttons) != nil,
                  "Unclaimed keyboard edge: \(point)")
        }
        check(KeyboardTouchRouting.nearestKey(at: CGPoint(x: 50, y: 11), in: root, keys: buttons) == nil,
              "Candidate bar stolen")
        check(KeyboardTouchRouting.nearestKey(at: CGPoint(x: -1, y: 40), in: root, keys: buttons) == nil,
              "Outside system view accepted")
        field.isHidden = true
        check(KeyboardTouchRouting.nearestKey(at: CGPoint(x: 50, y: 40), in: root, keys: buttons) == nil,
              "Hidden page accepted edge")
        field.isHidden = false

        let preview = KeycapPreviewView()
        field.addSubview(preview)
        func show(_ button: UIButton) {
            preview.show(title: "x", over: button, in: field, cornerRadius: 5,
                         fill: .white, text: .black, shadowOpacity: 0)
        }
        show(buttons[0])
        show(buttons[1])
        preview.hide(for: buttons[0])
        check(!preview.isHidden, "Earlier key release hid the current key preview")
        preview.hide(for: buttons[1])
        check(preview.isHidden, "Current key release left the preview visible")
        show(buttons[0])
        preview.hide()
        check(preview.isHidden, "Page cancellation did not hide preview")
        show(buttons[1])
        preview.hide(for: buttons[0])
        check(!preview.isHidden, "Old cancellation hid a new preview")
        check(!preview.isUserInteractionEnabled, "Preview must not intercept touches")

        if !failures.isEmpty {
            failures.prefix(20).forEach { print("FAIL: \($0)") }
            print("Total failures: \(failures.count)")
            exit(1)
        }
        print("PASS: UIKit hit/inside agreement at \(checkedPoints) points, disabled/page boundaries, preview ownership, edge routing, overlapping identities and 1000 repeated presses")
    }
}
