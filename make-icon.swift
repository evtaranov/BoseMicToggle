// Рисует иконку приложения и собирает AppIcon.icns.
// Запуск: swift make-icon.swift
//
// Каждый размер рисуется вектором отдельно, а не масштабированием одной
// большой картинки: на 16 и 32 пикселях уменьшенная версия превращается в кашу.

import AppKit

// MARK: - Рисование

func drawIcon(px: Int) -> NSBitmapImageRep {
    let size = CGFloat(px)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("не создался битмап \(px)") }

    rep.size = CGSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Поля по канону macOS: арт не упирается в края канваса.
    let inset = size * 0.085
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = plate.width * 0.225

    let plateePath = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.35, green: 0.28, blue: 0.62, alpha: 1),
        NSColor(srgbRed: 0.13, green: 0.15, blue: 0.32, alpha: 1),
    ])
    gradient?.draw(in: plateePath, angle: -90)

    let W = plate.width
    let H = plate.height
    let cx = plate.midX
    let cy = plate.midY

    NSColor.white.setFill()
    NSColor.white.setStroke()

    // Дуга наушников над микрофоном -- отсюда и берётся нажатие.
    // Дуга обрывается раньше подушек, иначе круглый торец сливается с ними
    // в каплю.
    let bandRadius = W * 0.335
    let bandCenter = CGPoint(x: cx, y: cy + H * 0.04)

    let band = NSBezierPath()
    band.appendArc(withCenter: bandCenter, radius: bandRadius,
                   startAngle: 48, endAngle: 132)
    band.lineWidth = W * 0.08
    band.lineCapStyle = .round
    NSColor(white: 1, alpha: 0.92).setStroke()
    band.stroke()

    // Амбушюры на концах дуги.
    NSColor(white: 1, alpha: 0.92).setFill()
    let padW = W * 0.135
    let padH = W * 0.20
    for angle in [42.0, 138.0] {
        let radians = angle * .pi / 180
        let point = CGPoint(x: bandCenter.x + cos(radians) * bandRadius,
                            y: bandCenter.y + sin(radians) * bandRadius)
        let pad = CGRect(x: point.x - padW / 2, y: point.y - padH * 0.6,
                         width: padW, height: padH)
        NSBezierPath(roundedRect: pad, xRadius: padW / 2, yRadius: padW / 2).fill()
    }

    NSColor.white.setFill()
    NSColor.white.setStroke()

    // Капсула микрофона.
    let capsuleW = W * 0.185
    let capsuleH = H * 0.30
    let capsule = CGRect(x: cx - capsuleW / 2, y: cy - H * 0.06,
                         width: capsuleW, height: capsuleH)
    NSBezierPath(roundedRect: capsule, xRadius: capsuleW / 2, yRadius: capsuleW / 2).fill()

    // Держатель -- дуга снизу вокруг капсулы.
    let cradle = NSBezierPath()
    cradle.appendArc(withCenter: CGPoint(x: cx, y: cy - H * 0.035),
                     radius: W * 0.155,
                     startAngle: 200, endAngle: 340)
    cradle.lineWidth = W * 0.055
    cradle.lineCapStyle = .round
    cradle.stroke()

    // Ножка и основание.
    let stemW = W * 0.055
    let stemTop = cy - H * 0.185
    let stemBottom = cy - H * 0.275
    let stem = CGRect(x: cx - stemW / 2, y: stemBottom,
                      width: stemW, height: stemTop - stemBottom)
    NSBezierPath(roundedRect: stem, xRadius: stemW / 2, yRadius: stemW / 2).fill()

    let baseW = W * 0.21
    let baseH = W * 0.055
    let base = CGRect(x: cx - baseW / 2, y: stemBottom - baseH / 2,
                      width: baseW, height: baseH)
    NSBezierPath(roundedRect: base, xRadius: baseH / 2, yRadius: baseH / 2).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("не вышло закодировать png")
    }
    try! data.write(to: url)
}

// MARK: - Сборка iconset

let projectDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath)

let iconset = projectDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Имена строго по требованиям iconutil.
let variants: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    writePNG(drawIcon(px: variant.px),
             to: iconset.appendingPathComponent("\(variant.name).png"))
}

// Отдельная большая картинка для README.
writePNG(drawIcon(px: 512), to: projectDir.appendingPathComponent("icon-preview.png"))

print("нарисовано \(variants.count) размеров в \(iconset.lastPathComponent)")
