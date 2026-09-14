import AppKit

/// 菜单栏只呈现 iOS App Icon 中的核心五段白色声波。
///
/// 整张蓝底 App Icon 在 18pt 菜单栏里会缩得过小；这里按原图比例重绘白色圆角声波，
/// 并标记为模板图，让 macOS 在深浅菜单栏中自动采用正确的前景色。
@MainActor
enum MenuBarIcon {
    static var image: NSImage {
        let canvas = NSSize(width: 18, height: 18)
        let heights: [CGFloat] = [5.0, 10.2, 14.0, 8.3, 5.8]
        let width: CGFloat = 2.0
        let gap: CGFloat = 1.55
        let totalWidth = width * 5 + gap * 4

        let image = NSImage(size: canvas, flipped: false) { _ in
            NSColor.black.setFill()
            for (index, height) in heights.enumerated() {
                let x = (canvas.width - totalWidth) / 2 + CGFloat(index) * (width + gap)
                let rect = NSRect(x: x, y: (canvas.height - height) / 2, width: width, height: height)
                NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
