import Foundation

/// 켜고 끄는 기능. 캘린더(아이콘 줄의 캘린더 탭, 메뉴 막대 캘린더 줄, 정리 뒤 일정 찾기·일정 제안 알림, 설정·온보딩의 캘린더 권한)는
/// 11/06 사용자 요청으로 꺼 둔다. 코드는 남겨 두고 숨은 설정으로 다시 켠다: defaults write com.sillog.app calendar -bool true (앱을 다시 켜야 적용)
enum AppFeatures {
    static let calendarKey = "calendar"

    static func calendar(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: calendarKey) }

    /// 앱이 뜰 때 한 번 읽는다 (켜는 중간에 바꾸면 화면 일부만 바뀌지 않게)
    static let calendarOn = calendar()
}
