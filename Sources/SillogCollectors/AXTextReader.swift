import ApplicationServices
import Foundation

/// 포커스된 창의 접근성 트리를 예산 안에서 훑어 화면 텍스트를 모은다.
/// OCR 보다 훨씬 싸고 정확하다. 예산(노드 수·시간)을 넘으면 거기까지만 돌려준다.
public struct AXTextReader: Sendable {
    public var maxNodes = 2500
    public var maxDepth = 35
    public var timeout: TimeInterval = 0.25
    public var maxChars = 20_000

    static let skipRoles: Set<String> = [
        "AXScrollBar", "AXImage", "AXSplitter", "AXGrowArea", "AXMenuBar", "AXMenu", "AXToolbar", "AXSecureTextField",
        "AXMenuBarItem", "AXRuler", "AXRulerMarker", "AXBusyIndicator", "AXProgressIndicator",
    ]
    static let valueRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXStaticText"]
    static let textRoles: Set<String> = [
        "AXStaticText", "AXTextField", "AXTextArea", "AXButton", "AXMenuItem", "AXCell", "AXHeading", "AXLink",
        "AXMenuButton", "AXPopUpButton", "AXComboBox", "AXCheckBox", "AXRadioButton", "AXTab",
    ]
    static let attributes = [kAXRoleAttribute as String, kAXValueAttribute as String, kAXTitleAttribute as String,
                             kAXDescriptionAttribute as String, kAXChildrenAttribute as String]

    public init() {}

    func read(window: AXUIElement) -> (text: String, truncated: Bool) {
        let started = Date()
        var stack: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var lines: [String] = []
        var seen = Set<String>()
        var count = 0, chars = 0, truncated = false

        while let (element, depth) = stack.popLast() {
            if count >= maxNodes || chars >= maxChars || Date().timeIntervalSince(started) >= timeout { truncated = true; break }
            count += 1
            let values = axMultiple(element, Self.attributes)
            let role = values[0] as? String ?? ""
            if Self.skipRoles.contains(role) { continue }          // 비밀번호 입력란은 하위까지 통째로 건너뜀

            if Self.textRoles.contains(role) {
                var text: String?
                if Self.valueRoles.contains(role) { text = values[1] as? String }
                text = text ?? (values[2] as? String) ?? (values[3] as? String)
                if let line = text?.trimmingCharacters(in: .whitespacesAndNewlines), line.count > 1, seen.insert(line).inserted {
                    lines.append(line)
                    chars += line.count
                }
            }
            // 웹 영역에 들어가면 깊이를 0부터 다시 센다 (Electron 껍데기가 예산을 다 먹지 않게).
            let nextDepth = role == "AXWebArea" ? 0 : depth + 1
            if nextDepth <= maxDepth, let children = values[4] as? [AXUIElement] {
                for child in children.reversed() { stack.append((child, nextDepth)) }
            }
        }
        return (String(lines.joined(separator: "\n").prefix(maxChars)), truncated)
    }
}
