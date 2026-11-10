import AVFoundation
import AppKit
import SwiftUI
import WorkGraphCore

/// 녹음 상세·목록 줄에 쓰는 문구 (화면 없이 시험한다)
enum RecordingDetail {
    /// "2026년 10월 10일 15:32 · 52분 10초"
    static func when(_ recording: Recording, timeZone: TimeZone = .current) -> String {
        "\(RecordingText.date(recording.startedAt, "yyyy년 M월 d일 HH:mm", timeZone: timeZone)) · \(RecordingText.duration(recording.duration))"
    }

    /// 목록 줄 둘째 줄: 날짜, 길이, 폴더 (또는 상태)
    static func subtitle(_ recording: Recording, home: String, timeZone: TimeZone = .current) -> String {
        let date = RecordingText.date(recording.startedAt, "M월 d일 HH:mm", timeZone: timeZone)
        let length = RecordingText.duration(recording.duration)
        let parts: [String]
        switch recording.status {
        case .recording: parts = [date, "녹음 중"]
        case .transcribing: parts = [date, "받아쓰는 중"]
        case .failed: parts = [date, length, "받아쓰기 실패"]
        case .ready:
            if !recording.hasTranscript {
                parts = [date, length, "받아쓴 내용 없음"]
            } else {
                let folder = recording.textPath.map { FileSuggestionCopy.folderLabel(($0 as NSString).deletingLastPathComponent, home: home) } ?? ""
                parts = [date, length, folder]
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "  ")
    }

    /// 상세 위쪽 안내: 받아쓰기 실패 이유, 받아쓴 글 파일이 없어진 것
    static func notice(_ recording: Recording, textExists: Bool) -> String? {
        if recording.status == .failed { return recording.error ?? "받아쓰지 못했어요." }
        if recording.textPath != nil, !textExists { return "받아쓴 글 파일을 찾을 수 없어요. 옮기거나 지웠어도 아래 글은 앱에 남아 있어요." }
        return nil
    }

    /// 녹음 파일 안내: "5일 뒤 지워져요", 지운 뒤, 실패해서 남겨 둔 것
    static func audioNote(_ recording: Recording, audioExists: Bool, now: Double) -> String? {
        if recording.audioDeletedAt != nil { return "녹음 파일은 7일이 지나 지웠어요" }
        guard audioExists else { return nil }
        if recording.status == .failed { return "받아쓰기에 실패한 녹음은 지우지 않아요" }
        guard recording.status == .ready, let readyAt = recording.readyAt else { return nil }
        let left = readyAt + RecordingStore.audioKeepDays * 86_400 - now
        return "\(max(1, Int((left / 86_400).rounded(.up))))일 뒤 지워져요"
    }

    /// 상세에 보이는 받아쓴 글: 발화마다 한 문단
    static func transcriptText(_ recording: Recording) -> String {
        recording.hasTranscript ? recording.utterances.joined(separator: "\n\n") : "받아쓴 내용이 없어요."
    }
}

/// 녹음 파일 듣기 (녹음 파일이 남아 있는 7일 동안만)
@MainActor
final class RecordingPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing = false
    private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if playing { stop(); return }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        player.play()
        self.player = player
        playing = true
    }

    func stop() {
        player?.stop()
        player = nil
        playing = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

/// 보관함의 녹음 상세: 요약, 받아쓴 글, 7일 동안 듣기, 받아쓴 글 파일, 실패했으면 다시 받아쓰기
struct RecordingDetailView: View {
    let recording: Recording
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = RecordingPlayer()
    @State private var showDelete = false

    private var textExists: Bool { recording.textPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }
    private var audioExists: Bool { recording.audioDeletedAt == nil && FileManager.default.fileExists(atPath: recording.audioPath) }

    var body: some View {
        VStack(spacing: 0) {
            LibrarySheetHeader(title: recording.displayTitle, detail: RecordingDetail.when(recording)) { dismiss() }
            VStack(alignment: .leading, spacing: 8) {
                if let notice = RecordingDetail.notice(recording, textExists: textExists) {
                    Text(notice).font(Brand.suit(12)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
                }
                if let summary = recording.summary, !summary.isEmpty {
                    Eyebrow("요약")
                    Text(summary).font(Brand.suit(12)).foregroundStyle(Brand.tabText).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Eyebrow("받아쓴 글").padding(.top, 6)
            }
            .padding(.horizontal, 27).padding(.top, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            ReadOnlyTextView(text: RecordingDetail.transcriptText(recording))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 15).padding(.bottom, 8)
            footer
        }
        .frame(width: 640, height: 520)
        .background(.white)
        .onDisappear { player.stop() }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if audioExists {
                Button { player.toggle(URL(fileURLWithPath: recording.audioPath)) } label: {
                    Label(player.playing ? "멈추기" : "듣기", systemImage: player.playing ? "stop.fill" : "play.fill")
                }
                .buttonStyle(BrandButtonStyle())
            }
            if let note = RecordingDetail.audioNote(recording, audioExists: audioExists, now: Date().timeIntervalSince1970) {
                Text(note).font(Brand.suit(11)).foregroundStyle(Brand.gray)
            }
            Spacer()
            if recording.status == .ready || recording.status == .failed {
                Button("녹음 삭제", role: .destructive) { showDelete = true }
                    .buttonStyle(BrandButtonStyle())
            }
            if recording.status == .failed, audioExists {
                Button("다시 받아쓰기") {
                    Task { await state.retranscribe(recording) }
                    dismiss()
                }
                .buttonStyle(BrandButtonStyle(kind: .primary))
            }
            if let path = recording.textPath, textExists {
                Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    .buttonStyle(BrandButtonStyle())
            }
            Button("닫기") { dismiss() }.buttonStyle(BrandButtonStyle())
        }
        .padding(.horizontal, 24).frame(height: 63)
        .brandGlass()
        .overlay(alignment: .top) { Rectangle().fill(Brand.hairline).frame(height: 1) }
        .alert("녹음을 삭제할까요?", isPresented: $showDelete) {
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) {
                state.deleteRecording(recording)
                dismiss()
            }
        } message: { Text("앱 안의 기록과 녹음 파일을 지워요. 받아쓴 글 파일(.md)은 남아요.") }
    }
}
