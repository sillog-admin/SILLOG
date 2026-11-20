// Draws the dmg window background: a mint gradient, an arrow from the app to Applications, and a short hint.
// The mint sits near 18% luminance so Finder's icon names read in both light (black) and dark (white) mode.
//   swift scripts/dmg/background.swift <fonts dir> <out dir>   -> background.png, background@2x.png
import AppKit

let args = CommandLine.arguments
let fonts = URL(fileURLWithPath: args[1]), outDir = URL(fileURLWithPath: args[2])
for name in ["SUIT-SemiBold.otf", "SUIT-Regular.otf"] {
    CTFontManagerRegisterFontsForURL(fonts.appendingPathComponent(name) as CFURL, .process, nil)
}

let size = CGSize(width: 660, height: 400)                   // window content; settings.py places the icons on it
func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func draw() {
    NSGradient(starting: rgb(0x2C978A), ending: rgb(0x1E7A70))!.draw(in: NSRect(origin: .zero, size: size), angle: -35)
    rgb(0xFFFFFF, 0.07).setFill()                                // soft blobs like the mascot's
    NSBezierPath(ovalIn: NSRect(x: -90, y: 250, width: 260, height: 260)).fill()
    NSBezierPath(ovalIn: NSRect(x: 540, y: -60, width: 200, height: 200)).fill()

    // Finder's own tab and path bars (a global setting) can hide the bottom of the window, so everything sits high
    let y = size.height - 165                                    // icon centers sit 165pt from the top, at x 180 and 480
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 266, y: y)); arrow.line(to: NSPoint(x: 392, y: y))
    arrow.move(to: NSPoint(x: 376, y: y + 15)); arrow.line(to: NSPoint(x: 393, y: y)); arrow.line(to: NSPoint(x: 376, y: y - 15))
    arrow.lineWidth = 6; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    rgb(0xFFFFFF, 0.92).setStroke(); arrow.stroke()

    func line(_ text: String, font: String, size points: CGFloat, alpha: CGFloat, top: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont(name: font, size: points) ?? .systemFont(ofSize: points),
                                                    .foregroundColor: rgb(0xFFFFFF, alpha)]
        let s = NSAttributedString(string: text, attributes: attrs), w = s.size()
        s.draw(at: NSPoint(x: (size.width - w.width) / 2, y: size.height - top - w.height / 2))
    }
    line("Applications 폴더로 끌어다 놓으세요", font: "SUIT-SemiBold", size: 16, alpha: 1, top: 292)
    line("Drag SILLOG to Applications", font: "SUIT-Regular", size: 12, alpha: 0.75, top: 316)
}

for (scale, name) in [(1, "background.png"), (2, "background@2x.png")] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size                                              // draw in points; the bitmap holds the scale
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
}
