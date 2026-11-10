import Foundation

/// 받아쓴 줄 다듬기: Whisper 가 작은 소리·잡음에서 지어내는 줄을 거른다 (10/13 강의 녹음: 출석 부르는 구간에서 '최선은' 40번, '-' 여러 줄).
/// 같은 말(문장부호 빼고)이 세 번 넘게 잇달아 나오면 한 줄만 남기고, 글자·숫자가 없는 줄은 뺀다. 두 번까지는 실제로 한 말로 본다
public enum TranscriptCleanup {
    public static func clean(_ lines: [String]) -> [String] {
        var runs: [(key: String, lines: [String])] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = String(String.UnicodeScalarView(line.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })).lowercased()
            guard !key.isEmpty else { continue }
            if runs.last?.key == key { runs[runs.count - 1].lines.append(line) } else { runs.append((key, [line])) }
        }
        return runs.flatMap { $0.lines.count > 2 ? [$0.lines[0]] : $0.lines }
    }
}
