import UIKit

/// 系统键盘按下字母键时向上弹出的那颗"放大键帽"。**纯视觉反馈,不发任何声音**
/// (2026-08-04 用户明确要求:要 iPhone 自带键盘那种反馈,但不要按键音)。
///
/// 形状是一整条闭合路径:上方的放大头 + 中间收窄的颈 + 下方与真实键帽同尺寸的脚。
/// 脚正好盖在被按的键上,所以按下瞬间视觉上是"这颗键长高了",而不是"多了一个浮层"。
/// 分成两块画会在颈部留下拼缝,所以这里一定是一条路径。
final class KeycapPreviewView: UIView {
    /// 放大头比键帽每侧宽出的量。
    static let flare: CGFloat = 11
    /// 放大头本身的高度。
    static let headHeight: CGFloat = 46
    /// 颈(头与键帽之间的收窄段)高度。
    static let neckHeight: CGFloat = 10
    /// 弹出后整体比键帽高出多少——调用方据此判断上方空间是否够。
    static var totalRise: CGFloat { headHeight + neckHeight }

    private let shape = CAShapeLayer()
    private let label = UILabel()
    private weak var owningButton: UIButton?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false   // 绝不能截走键上的触摸,否则抬手事件丢失、键卡在按下态
        isHidden = true
        shape.shadowOffset = CGSize(width: 0, height: 1)
        shape.shadowRadius = 0
        layer.addSublayer(shape)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("KeycapPreviewView 只在代码里创建") }

    /// 把预览挂到 `button` 上方。`container` 通常是键盘根视图——它必须不裁剪子视图,
    /// 第一排字母的放大头会伸进候选栏那一带(系统键盘同样如此)。
    func show(title: String,
              over button: UIButton,
              in container: UIView,
              cornerRadius: CGFloat,
              fill: UIColor,
              text: UIColor,
              shadowOpacity: Float) {
        guard let parent = button.superview else { return }
        let keyFrame = parent.convert(button.frame, to: container)
        guard keyFrame.width > 0, keyFrame.height > 0 else { return }
        owningButton = button

        let width = keyFrame.width + 2 * Self.flare
        let height = Self.totalRise + keyFrame.height
        // 贴边的键(q / p / 数字排两端)放大头会超出屏幕,这里把整块夹回容器内;
        // 颈仍然对准真实键帽——所以路径用 keyOriginX 而不是恒定的 flare 定位脚。
        let unclampedX = keyFrame.minX - Self.flare
        let x = min(max(unclampedX, 0), max(0, container.bounds.width - width))
        frame = CGRect(x: x, y: keyFrame.minY - Self.totalRise, width: width, height: height)

        let path = Self.outlinePath(
            size: bounds.size,
            keyOriginX: keyFrame.minX - x,
            keyWidth: keyFrame.width,
            keyCornerRadius: cornerRadius
        )
        shape.path = path.cgPath
        shape.shadowPath = path.cgPath
        shape.fillColor = fill.resolvedColor(with: traitCollection).cgColor
        shape.shadowColor = UIColor.black.cgColor
        shape.shadowOpacity = shadowOpacity

        label.frame = CGRect(x: 0, y: 0, width: width, height: Self.headHeight)
        label.text = title
        label.textColor = text
        // 字母 34pt;中文/多字符标签(数字符号页的 "¥" 等)沿用同一字号,过宽时自动缩。
        label.font = .systemFont(ofSize: 34, weight: .regular)

        container.bringSubviewToFront(self)
        isHidden = false
    }

    func hide() {
        owningButton = nil
        isHidden = true
    }

    /// 双指交替时，先前按键的抬手/滑出不能关闭后来按键的预览。
    func hide(for button: UIButton) {
        guard owningButton === button else { return }
        hide()
    }

    /// 头(圆角矩形)—颈(两条三次曲线内收)—脚(与键帽同宽同圆角)的单条闭合路径。
    private static func outlinePath(size: CGSize,
                                    keyOriginX: CGFloat,
                                    keyWidth: CGFloat,
                                    keyCornerRadius: CGFloat) -> UIBezierPath {
        let w = size.width
        let total = size.height
        let headBottom = headHeight
        let keyTop = headHeight + neckHeight
        let keyLeft = keyOriginX
        let keyRight = keyOriginX + keyWidth
        let headRadius: CGFloat = 10
        let footRadius = min(keyCornerRadius, keyWidth / 2)

        let path = UIBezierPath()
        // 头:左上 → 右上
        path.move(to: CGPoint(x: 0, y: headRadius))
        path.addArc(withCenter: CGPoint(x: headRadius, y: headRadius),
                    radius: headRadius, startAngle: .pi, endAngle: -.pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: w - headRadius, y: 0))
        path.addArc(withCenter: CGPoint(x: w - headRadius, y: headRadius),
                    radius: headRadius, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        // 右侧下行 → 右颈内收
        path.addLine(to: CGPoint(x: w, y: headBottom))
        path.addCurve(to: CGPoint(x: keyRight, y: keyTop),
                      controlPoint1: CGPoint(x: w, y: headBottom + neckHeight * 0.6),
                      controlPoint2: CGPoint(x: keyRight, y: headBottom + neckHeight * 0.4))
        // 脚:右下 → 左下
        path.addLine(to: CGPoint(x: keyRight, y: total - footRadius))
        path.addArc(withCenter: CGPoint(x: keyRight - footRadius, y: total - footRadius),
                    radius: footRadius, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: keyLeft + footRadius, y: total))
        path.addArc(withCenter: CGPoint(x: keyLeft + footRadius, y: total - footRadius),
                    radius: footRadius, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        // 左颈外扩 → 回到起点
        path.addLine(to: CGPoint(x: keyLeft, y: keyTop))
        path.addCurve(to: CGPoint(x: 0, y: headBottom),
                      controlPoint1: CGPoint(x: keyLeft, y: headBottom + neckHeight * 0.4),
                      controlPoint2: CGPoint(x: 0, y: headBottom + neckHeight * 0.6))
        path.close()
        return path
    }
}
