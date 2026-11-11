import CoreGraphics
import Vision

/// 접근성 텍스트가 거의 없을 때만 쓰는 폴백 (캔버스 앱, 게임, 원격 데스크톱 등).
public enum OCRReader {
    public static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return ""
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
