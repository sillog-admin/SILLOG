import CoreGraphics

public enum IdleMonitor {
    /// 마지막 키보드·마우스 입력 이후 지난 시간(초).
    public static func secondsSinceLastInput() -> Double {
        guard let anyInput = CGEventType(rawValue: UInt32.max) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}
