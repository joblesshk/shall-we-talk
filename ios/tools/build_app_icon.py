"""静墨 Quiet Ink — App 图标 6.1「静蓝底 · 波形」。

几何全部来自视觉定稿 §06 的「共用几何」:画布 1024,五根条宽 = 边长 × 0.0469、
gap 同宽,高度比 0.137/0.289/0.383/0.227/0.156(即键盘就绪态 ② 的 12/22/30/18/13
等比放大),首尾两根 55% 不透明度,端头全圆角,整组水平垂直居中、不做光学偏移。
圆角交给 iOS 自己的 squircle 遮罩,这里一律输出满幅方图。
"""

from PIL import Image, ImageDraw

SIZE = 1024
SS = 4  # 超采样倍数,画完再缩,拿到干净的圆头

RATIOS = [0.137, 0.289, 0.383, 0.227, 0.156]
BAR_W_RATIO = 0.0469
EDGE_ALPHA = 0.55


def hex_rgb(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def render(background, bar_color, path):
    """background 为 None 时输出透明底(tinted 用)。"""
    canvas = SIZE * SS
    bg = (0, 0, 0, 0) if background is None else hex_rgb(background) + (255,)
    image = Image.new("RGBA", (canvas, canvas), bg)
    draw = ImageDraw.Draw(image)

    bar_w = BAR_W_RATIO * canvas
    gap = bar_w
    total_w = len(RATIOS) * bar_w + (len(RATIOS) - 1) * gap
    x = (canvas - total_w) / 2
    rgb = hex_rgb(bar_color)

    for index, ratio in enumerate(RATIOS):
        height = ratio * canvas
        top = (canvas - height) / 2
        alpha = EDGE_ALPHA if index in (0, len(RATIOS) - 1) else 1.0
        draw.rounded_rectangle(
            [x, top, x + bar_w, top + height],
            radius=bar_w / 2,
            fill=rgb + (round(alpha * 255),),
        )
        x += bar_w + gap

    out = image.resize((SIZE, SIZE), Image.LANCZOS)
    # App Store 主图标不允许带 alpha 通道;只有 tinted 那份需要透明底。
    if background is not None:
        out = out.convert("RGB")
    out.save(path)
    print(f"wrote {path} ({out.mode})")


if __name__ == "__main__":
    import sys
    out = sys.argv[1].rstrip("/")
    render("#3F6C9F", "#FCFBF9", f"{out}/icon-1024.png")
    render("#2C2A27", "#8AABD1", f"{out}/icon-dark-1024.png")
    render(None, "#FFFFFF", f"{out}/icon-tinted-1024.png")
