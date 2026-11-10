// 앱 아이콘 생성: 어두운 둥근 사각형 위에 그래프 뷰와 같은 색의 노드 세 개와 연결선.
// 사용: swift scripts/make-icon.swift <출력.icns>
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WorkGraph-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = size * 0.1
    let body = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2),
                            xRadius: size * 0.185, yRadius: size * 0.185)
    NSGradient(starting: NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.19, alpha: 1),
               ending: NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.11, alpha: 1))!.draw(in: body, angle: -90)

    let nodes: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
        (0.34, 0.64, 0.075, NSColor(calibratedRed: 0.66, green: 0.51, blue: 1.00, alpha: 1)),   // 업무
        (0.68, 0.60, 0.058, NSColor(calibratedRed: 0.35, green: 0.66, blue: 0.90, alpha: 1)),   // 참고자료
        (0.50, 0.34, 0.058, NSColor(calibratedRed: 0.48, green: 0.77, blue: 0.50, alpha: 1)),   // 산출물
        (0.74, 0.34, 0.036, NSColor(calibratedRed: 0.94, green: 0.48, blue: 0.60, alpha: 1)),   // 주제
    ]
    let links = [(0, 1), (0, 2), (1, 2), (2, 3)]
    NSColor(calibratedWhite: 1, alpha: 0.28).setStroke()
    for (a, b) in links {
        let path = NSBezierPath()
        path.lineWidth = size * 0.014
        path.move(to: NSPoint(x: nodes[a].0 * size, y: nodes[a].1 * size))
        path.line(to: NSPoint(x: nodes[b].0 * size, y: nodes[b].1 * size))
        path.stroke()
    }
    for (x, y, r, color) in nodes {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: (x - r) * size, y: (y - r) * size, width: r * 2 * size, height: r * 2 * size)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try draw(points * scale).write(to: iconset.appendingPathComponent(name))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "아이콘 생성: \(output)" : "iconutil 실패")
