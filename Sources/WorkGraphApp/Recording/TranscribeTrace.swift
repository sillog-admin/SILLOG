import AVFoundation
import Foundation
import WorkGraphCore

/// 개발용 진단: 녹음 파일 하나를 앱과 같은 방식으로 받아쓰며 과정을 적고 끝난다. DB·실행 잠금·수집기는 만들지 않는다.
/// 엔진: 기본은 Whisper 로 파일 전체, apple 은 애플 기기 안 인식(결과마다 마지막 결과인지·발화 끝 표시·끝 시각·글),
/// live 는 녹음 중 미리 받아쓰기(파일을 녹음기처럼 CaptureWriter 로 흘려보내며 조각마다 받아쓰고, 다 흘려보낸 뒤 글이 나오기까지 걸린 시간).
/// 음성 인식 권한은 앱 번들에만 있어서 Sillog 번들로 띄운다:
///   open -n Sillog.app --env 'WORKGRAPH_TRANSCRIBE_TRACE=<녹음 파일>|<적을 파일>' [--env WORKGRAPH_TRANSCRIBE_ENGINE=apple|live]
///     [--env WORKGRAPH_TRANSCRIBE_GAIN=2] (apple) [--env WORKGRAPH_TRANSCRIBE_SPEED=1] (live: 녹음보다 몇 배 빨리 흘려보낼지, 기본 1)
enum TranscribeTrace {
    static func run(_ spec: String) -> Never {
        let parts = spec.components(separatedBy: "|")
        let audio = URL(fileURLWithPath: parts[0])
        let out = URL(fileURLWithPath: parts.count > 1 ? parts[1] : parts[0] + ".trace.txt")
        let lines = Lines()
        func finish(_ last: String) -> Never {
            lines.append(last)
            try? lines.text.write(to: out, atomically: true, encoding: .utf8)
            exit(0)
        }
        Task.detached {
            let duration = (try? AVAudioFile(forReading: audio)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
            lines.append(String(format: "audio %@ %.1fs", audio.lastPathComponent, duration))
            do {
                let environment = ProcessInfo.processInfo.environment
                if environment["WORKGRAPH_TRANSCRIBE_ENGINE"] == "live" {
                    let speed = environment["WORKGRAPH_TRANSCRIBE_SPEED"].flatMap(Double.init) ?? 1
                    finish(result(try await live(audio, speed: speed, lines: lines)))
                }
                let gain = environment["WORKGRAPH_TRANSCRIBE_GAIN"].flatMap(Float.init)   // 배수 비교용 (애플 인식)
                // 엔진: 기본은 앱과 같은 Whisper (실패해도 애플 인식으로 넘어가지 않고 그대로 적는다), apple 이면 애플 기기 안 인식
                let transcriber: any Transcribing = environment["WORKGRAPH_TRANSCRIBE_ENGINE"] == "apple"
                    ? SpeechTranscriber(trace: { lines.append($0) }, gainOverride: gain)
                    : WhisperTranscriber(fallback: nil, trace: { lines.append($0) })
                let started = Date()
                let utterances = try await transcriber.transcribe(audio: audio, duration: duration) { _ in }
                lines.append(String(format: "elapsed %.1fs", Date().timeIntervalSince(started)))
                finish(result(utterances))
            } catch {
                finish("== failed \(error)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1800) { finish("== timed out after 1800s") }
        dispatchMain()
    }

    /// 앱이 저장하는 글처럼 다듬은 줄 (TranscriptCleanup)
    private static func result(_ utterances: [String]) -> String {
        let cleaned = TranscriptCleanup.clean(utterances)
        return "== utterances \(cleaned.count) (raw \(utterances.count))\n" + cleaned.map { "- " + $0 }.joined(separator: "\n")
    }

    /// 녹음 중 미리 받아쓰기: 파일을 4096 프레임씩 녹음기처럼(speed 배 빠르게) CaptureWriter 에 넣고, 끝나면 남은 조각까지 기다린다
    private static func live(_ audio: URL, speed: Double, lines: Lines) async throws -> [String] {
        let started = Date()
        await WhisperEngine.shared.prewarm()
        lines.append(String(format: "model ready %.1fs", Date().timeIntervalSince(started)))
        let session = LiveTranscription { samples in
            let begun = Date()
            let result = try await WhisperEngine.shared.transcribe(samples: samples)
            lines.append(String(format: "chunk %.1fs audio → %.1fs, %d lines", Double(samples.count) / IncrementalTranscription.sampleRate,
                                Date().timeIntervalSince(begun), result.count))
            return result
        }
        let file = try AVAudioFile(forReading: audio)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("live-trace-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: copy) }
        let writer = try CaptureWriter(url: copy, input: file.processingFormat) { session.append($0) }
        let feeding = Date()
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            writer.write(buffer)
            try await Task.sleep(nanoseconds: UInt64(Double(buffer.frameLength) / file.processingFormat.sampleRate / speed * 1_000_000_000))
        }
        writer.close()
        lines.append(String(format: "fed %.1fs of audio in %.1fs", writer.seconds, Date().timeIntervalSince(feeding)))
        let stopped = Date()
        let utterances = try await session.finish()
        lines.append(String(format: "ready %.1fs after the end", Date().timeIntervalSince(stopped)))
        return utterances
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ line: String) { lock.lock(); items.append(line); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return items.joined(separator: "\n") + "\n" }
    }
}
