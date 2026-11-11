import Foundation

/// 파일 정리 알림 문구 (Figma OUT-07). 알림 버튼은 옮기기·무시
public enum FileSuggestionCopy {
    public static let title = "파일을 정리할까요?"

    /// 두 줄: 파일 이름, 그 아래 옮길 곳 흐름. 한 문장에 다 넣으면 긴 이름에 섞여 안 읽혀서 나눈다(10/30)
    /// "통계학_수업자료.pdf\n→ 문서 › 통계학"
    public static func body(fileName: String, folder: String, home: String) -> String {
        "\(fileName)\n→ \(folderLabel(folder, home: home).replacingOccurrences(of: " / ", with: " › "))"
    }

    /// 받아쓴 녹음의 폴더 제안 알림 (버튼은 옮기기·무시 그대로)
    public static let recordingTitle = "받아쓴 녹음을 정리할까요?"

    /// 파일 정리 알림과 같은 두 줄: "2026-10-10 자료구조 3주차 강의.md\n→ 문서 › 학교 › 자료구조"
    public static func recordingBody(fileName: String, folder: String, home: String) -> String {
        body(fileName: fileName, folder: folder, home: home)
    }

    /// 폴더 제안이 없을 때: 저장한 곳만 알린다
    public static let transcribedTitle = "녹음을 받아썼어요"

    public static func transcribedBody(fileName: String, folder: String, home: String) -> String {
        "'\(fileName)'를 \(folderLabel(folder, home: home)) 폴더에 저장했어요."
    }

    /// 을/를: 마지막 글자가 한글이면 받침으로 고르고, 그 밖(확장자로 끝나는 파일 이름 등)은 Figma 처럼 "을"
    public static func objectParticle(_ word: String) -> String {
        guard let last = word.unicodeScalars.last, (0xAC00...0xD7A3).contains(last.value) else { return "을" }
        return (last.value - 0xAC00) % 28 == 0 ? "를" : "을"
    }

    /// 폴더를 "문서 / 통계학" 처럼 보여 준다. 홈 바로 아래 기본 폴더는 Finder 의 한국어 이름, 홈 자체는 "홈"
    public static func folderLabel(_ path: String, home: String) -> String {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        if trimmed == home { return "홈" }
        guard trimmed.hasPrefix(home + "/") else { return trimmed.split(separator: "/").joined(separator: " / ") }
        var parts = trimmed.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        if let first = parts.first, let name = homeFolders[first] { parts[0] = name }
        return parts.joined(separator: " / ")
    }

    static let homeFolders = ["Desktop": "데스크탑", "Documents": "문서", "Downloads": "다운로드",
                              "Movies": "동영상", "Music": "음악", "Pictures": "사진"]
}
