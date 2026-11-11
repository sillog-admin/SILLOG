import ApplicationServices
import Foundation

// 접근성(AX) API 읽기 도우미. 다른 프로세스에 묻는 호출이라 항상 실패할 수 있고, 그때는 nil 을 돌려준다.

func axCopy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
}

func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    guard let value = axCopy(element, attribute) else { return nil }
    if let text = value as? String { return text.isEmpty ? nil : text }
    if let url = value as? URL { return url.absoluteString }
    return nil
}

func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = axCopy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    (axCopy(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

/// 여러 속성을 한 번의 프로세스 간 호출로 읽는다 (노드마다 호출 1회).
func axMultiple(_ element: AXUIElement, _ attributes: [String]) -> [CFTypeRef?] {
    var values: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
          let list = values as? [AnyObject], list.count == attributes.count else {
        return Array(repeating: nil, count: attributes.count)
    }
    return list.map { item in CFGetTypeID(item) == AXValueGetTypeID() ? nil : item }   // 없는 속성은 AXValue(에러)로 온다
}

/// 포커스된 창: AXFocusedWindow → AXMainWindow → 첫 번째 창.
func axFocusedWindow(of app: AXUIElement) -> AXUIElement? {
    axElement(app, kAXFocusedWindowAttribute as String)
        ?? axElement(app, kAXMainWindowAttribute as String)
        ?? (axCopy(app, kAXWindowsAttribute as String) as? [AXUIElement])?.first
}

func axWindowFrame(_ window: AXUIElement) -> CGRect? {
    guard let position = axCopy(window, kAXPositionAttribute as String), CFGetTypeID(position) == AXValueGetTypeID(),
          let size = axCopy(window, kAXSizeAttribute as String), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
    return CGRect(origin: point, size: dimensions)
}
