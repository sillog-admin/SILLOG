import Foundation

/// 백그라운드 앱이라 무슨 일이 있었는지 볼 곳이 필요하다. 데이터 폴더의 app.log 에 한 줄씩 남긴다.
/// 화면 내용이나 토큰은 절대 쓰지 않는다 (단계 전환, 권한 요청 결과, 배치 결과만).
public enum AppLog {
    private static let queue = DispatchQueue(label: "workgraph.applog")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public static var fileURL: URL {
        URL(fileURLWithPath: WGDatabase.defaultPath()).deletingLastPathComponent().appendingPathComponent("app.log")
    }

    /// 테스트 중에는 사용자의 실제 로그에 쓰지 않는다
    static let isTesting = NSClassFromString("XCTestCase") != nil

    public static func write(_ message: String) {
        guard !isTesting else { return }
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async {
            let url = fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber, size.intValue > 1_000_000 {
                try? FileManager.default.removeItem(at: url)               // 1MB 넘으면 새로 시작
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
