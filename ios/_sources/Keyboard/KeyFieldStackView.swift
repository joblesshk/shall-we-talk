import UIKit

/// 字母/符号键区：键帽与键缝共用同一个按钮分区。
/// 命中和按钮的point(inside:)共用分区；提交由独立触摸身份驱动，
/// 不再依赖UIButton在松手时判断inside。真机触摸效果另行验收。
final class KeyFieldStackView: UIStackView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit is UIButton { return hit }
        // 只在本键区可交互时改判——另一页(字母/符号)是靠 isUserInteractionEnabled 关掉的,
        // 不作这层判断的话隐藏那页会把触摸抢走。
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, bounds.contains(point) else {
            return hit
        }
        guard let key = key(at: point), key.isEnabled else { return hit }
        return key
    }

    /// 不调用子按钮hitTest/point，避免与KeyFieldButton递归。
    /// 距离相同按排列顺序确定归属，整块键区每个点只属于一个键。
    func key(at point: CGPoint) -> UIButton? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, bounds.contains(point) else { return nil }
        var best: (button: UIButton, distance: CGFloat)?
        for row in arrangedSubviews where !row.isHidden && row.isUserInteractionEnabled && row.alpha > 0.01 {
            for case let key as UIButton in row.subviews
            where key.isUserInteractionEnabled && !key.isHidden && key.alpha > 0.01 {
                let frame = key.convert(key.bounds, to: self)
                let distance = Self.squaredDistance(from: point, to: frame)
                if best == nil || distance < best!.distance { best = (key, distance) }
            }
        }
        return best?.button
    }

    /// 点到矩形的平方距离(点在矩形内为 0)。用平方值比较,省掉每次开方。
    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

/// 每个系统触摸独立提交；不使用 UIButton 的单一 tracking 状态或松手命中条件。
/// primaryActionTriggered 是输入事件，touchDown/结束事件只负责外观。
final class KeyFieldButton: UIButton {
    private var activePresses = Set<ObjectIdentifier>()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
    }

    func beginPress(_ id: ObjectIdentifier) {
        guard isEnabled, isUserInteractionEnabled, !isHidden,
              activePresses.insert(id).inserted else { return }
        sendActions(for: .touchDown)
        sendActions(for: .primaryActionTriggered)
    }

    func endPress(_ id: ObjectIdentifier) {
        guard activePresses.remove(id) != nil else { return }
        if activePresses.isEmpty { sendActions(for: .touchUpOutside) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 同一批触摸按系统时间排序，不合并时间相近的点击。
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            beginPress(ObjectIdentifier(touch))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { endPress(ObjectIdentifier(touch)) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { endPress(ObjectIdentifier(touch)) }
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        sendActions(for: .primaryActionTriggered)
        return true
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isEnabled, isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return false }
        var ancestor = superview
        while let view = ancestor {
            guard view.isUserInteractionEnabled, !view.isHidden, view.alpha > 0.01 else { return false }
            if let field = view as? KeyFieldStackView {
                return field.key(at: convert(point, to: field)) === self
            }
            ancestor = view.superview
        }
        return super.point(inside: point, with: event)
    }
}

/// 仅给文字按键区的空白补位；候选栏及已命中的控件仍保留原行为。
enum KeyboardTouchRouting {
    static func nearestKey(at point: CGPoint, in root: UIView, keys: [KeyFieldButton]) -> KeyFieldButton? {
        let visible = keys.filter { key in
            guard key.isEnabled, key.bounds.width > 0, key.bounds.height > 0 else { return false }
            var node: UIView? = key
            while let view = node {
                guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled else { return false }
                if view === root { return true }
                node = view.superview
            }
            return false
        }
        let frames = visible.map { $0.convert($0.bounds, to: root) }
        guard let top = frames.map(\.minY).min(), root.bounds.contains(point),
              point.y >= top - 8 else { return nil }
        // 横向到视图边界，底部到应用键盘视图边界；不跨越系统区域。
        return zip(visible, frames).min { lhs, rhs in
            func distance(_ rect: CGRect) -> CGFloat {
                let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
                let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
                return dx * dx + dy * dy
            }
            return distance(lhs.1) < distance(rhs.1)
        }?.0
    }
}


/// 用普通UIView触摸入口统一接收按键区事件，避免UIControl在视觉bounds外过滤事件。
class KeyboardTouchInputView: UIInputView {
    var nearbyKey: ((CGPoint) -> KeyFieldButton?)?
    private var owners: [ObjectIdentifier: KeyFieldButton] = [:]
    private var touchSurface: UIView?

    func installTouchSurface() {
        guard touchSurface == nil else { return }
        let surface = UIView(frame: bounds)
        // iOS键盘扩展会丢弃完全透明像素上的触摸。填充只负责绘制，
        // 不参与命中；真实控件/候选滚动栏仍由下方视图和根入口分配。
        surface.isUserInteractionEnabled = false
        surface.backgroundColor = UIColor.black.withAlphaComponent(0.01)
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(surface)
        touchSurface = surface
    }

    override init(frame: CGRect, inputViewStyle: UIInputView.Style) {
        super.init(frame: frame, inputViewStyle: inputViewStyle)
        isMultipleTouchEnabled = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isMultipleTouchEnabled = true
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01,
              bounds.contains(point) else { return hit }
        var node = hit
        while let view = node, view !== self {
            if let key = view as? KeyFieldButton { return key.isEnabled ? self : hit }
            if view is UIControl || view is UIScrollView { return hit }
            node = view.superview
        }
        return nearbyKey?(point) != nil ? self : hit
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            let id = ObjectIdentifier(touch)
            guard owners[id] == nil, let key = nearbyKey?(touch.location(in: self)) else { continue }
            owners[id] = key
            key.beginPress(id)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            owners.removeValue(forKey: id)?.endPress(id)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}
