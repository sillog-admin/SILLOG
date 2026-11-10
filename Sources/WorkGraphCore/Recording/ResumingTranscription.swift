import Foundation

/// 기기 안 인식은 말이 한동안 끊기면 파일 끝까지 가지 않고 끝낸다 (10/13 측정: 77초 녹음에서 34초 뒤 40초를 놓침).
/// 그래서 마지막 말이 끝난 자리 바로 뒤에서 다시 시작하고, 아무것도 안 나오면 step 초씩 건너뛰며 파일 끝까지 받아쓴다
public enum ResumingTranscription {
    /// 한 번 받아쓴 결과: 발화들과, 마지막 발화가 끝난 시각 (이번 시작점부터 초, 모르면 nil)
    public struct Pass: Equatable, Sendable {
        public var utterances: [String]
        public var lastEnd: Double?
        public init(utterances: [String], lastEnd: Double?) { self.utterances = utterances; self.lastEnd = lastEnd }
    }

    /// 다시 시작할 때 마지막 말 끝에서 띄우는 틈 (초)
    static let gap = 0.2
    /// 이만큼 안 남았으면 더 받아쓰지 않는다 (초)
    static let tail = 1.0

    /// Args: duration 은 녹음 길이, step 은 아무것도 안 나왔을 때 건너뛸 초, progress 는 0~1, pass 는 start 초부터 끝까지 한 번 받아쓴다.
    /// Returns: 차례대로 이어 붙인 발화들.
    /// Raises: pass 의 오류 그대로.
    public static func run(duration: Double, step: Double = 10, progress: (Double) -> Void = { _ in },
                           pass: (Double) async throws -> Pass) async throws -> [String] {
        var start = 0.0, utterances: [String] = []
        while start < duration - tail {
            let result = try await pass(start)
            utterances += result.utterances
            // 마지막 말 바로 뒤로. 끝 시각을 모르거나 아무것도 안 나왔으면 step 만큼. 늘 앞으로만 간다
            let resume = result.lastEnd.map { start + $0 + gap } ?? start + step
            start = max(resume, start + (result.utterances.isEmpty ? step : gap))
            progress(min(1, start / max(duration, 1)))
        }
        return utterances
    }
}

/// 받아쓰기 전 소리 크기 맞추기: 녹음이 작으면(멀리서 말하면) 인식기가 말소리로 못 알아듣는다.
/// 말소리 부분(0.1초 창 RMS 위쪽 10%)이 -16dBFS 쯤 되게 키운다. 최대 3배, 줄이지는 않는다. 원본 녹음 파일은 그대로 둔다.
/// 10/13: 77초 녹음을 1·1.5·2·3·4·8배로 비교하니 2~3배가 앞뒤 모두 가장 많이 받아썼다 (더 키우면 잡음도 커져 뒤쪽이 토막 난다)
public enum TranscriptionGain {
    /// 말소리 부분의 목표 크기 (RMS, 약 -16dBFS)
    public static let target: Float = 0.16
    public static let maxFactor: Float = 3

    /// Args: windowRMS 는 0.1초 창마다의 RMS.
    /// Returns: 곱할 배수 (1...8).
    public static func factor(windowRMS: [Float]) -> Float {
        let heard = windowRMS.filter { $0 > 0 }.sorted()
        guard !heard.isEmpty else { return 1 }
        let speech = heard[min(heard.count - 1, Int(Double(heard.count) * 0.9))]
        return min(maxFactor, max(1, target / speech))
    }

    /// 키운 소리가 1을 넘지 않게 부드럽게 눌러 준다 (작은 소리는 거의 그대로 배수만큼)
    public static func apply(_ sample: Float, factor: Float) -> Float { factor == 1 ? sample : tanhf(sample * factor) }
}
