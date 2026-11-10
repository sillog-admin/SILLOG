import AVFoundation
import XCTest
@testable import WorkGraphApp

/// 녹음기 탭 소리 → m4a(AAC 44.1kHz 모노, 예전 녹음과 같은 형식)와 미리 받아쓰기용 16kHz 모노 소리
final class CaptureWriterTests: XCTestCase {
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var samples = 0
        func add(_ count: Int) { lock.lock(); samples += count; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return samples }
    }

    /// 마이크처럼 48kHz 스테레오 사인파를 4096 프레임씩
    private func microphone(seconds: Double) -> [AVAudioPCMBuffer] {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        var buffers: [AVAudioPCMBuffer] = [], frame = 0
        let total = Int(48_000 * seconds)
        while frame < total {
            let count = min(4096, total - frame)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<2 {
                for index in 0..<count { buffer.floatChannelData![channel][index] = Float(0.2 * sin(Double(frame + index) * 0.06)) }
            }
            buffers.append(buffer)
            frame += count
        }
        return buffers
    }

    func testMicrophoneSoundBecomesTheSameM4AAndA16kHzStream() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let collected = Collected()
        let buffers = microphone(seconds: 3)
        let writer = try CaptureWriter(url: url, input: buffers[0].format) { collected.add($0.count) }
        for buffer in buffers { writer.write(buffer) }
        XCTAssertEqual(writer.seconds, 3, accuracy: 0.1)
        writer.close()

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 3, accuracy: 0.15, "녹음 길이 그대로")
        XCTAssertEqual(Double(collected.count) / 16_000, 3, accuracy: 0.15, "미리 받아쓰기로 간 소리도 같은 길이")
    }
}
