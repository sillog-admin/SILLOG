import Foundation
import SillogCore

/// The SUMUNJANG model download, as 설정 > 일반 > 보안 shows it.
enum SumunjangDownload: Equatable {
    case idle, downloading(Double), failed
}

extension AppState {
    /// Starts the one-time download when the setting is on and the model is missing.
    /// Until the model is ready, batches wait and recording goes on.
    func prepareSumunjang() {
        guard settings.sumunjang, !isPreview, !SumunjangModel.shared.isReady else { return }
        if case .downloading = sumunjangDownload { return }
        sumunjangDownload = .downloading(0)
        Task { [weak self] in
            do {
                try await SumunjangModel.shared.download { fraction in
                    Task { @MainActor in if case .downloading = self?.sumunjangDownload { self?.sumunjangDownload = .downloading(fraction) } }
                }
                AppLog.write("수문장 모델을 받음")
                self?.sumunjangDownload = .idle
                await self?.runBatch(force: false)
            } catch {
                AppLog.write("수문장 모델을 받지 못함: \(error)")
                self?.sumunjangDownload = .failed
            }
        }
    }

    /// Returns: the observations since `since` that SUMUNJANG does not flag; none when it cannot score them,
    ///   so a suggestion never leaks a sensitive screen.
    func withoutSensitive(_ observations: [Observation], since: Double) async -> [Observation] {
        let window = observations.filter { $0.ts >= since }
        guard settings.sumunjang, let db, !window.isEmpty else { return window }
        do {
            let flagged = try await Sumunjang().sensitiveIDs(window, db: db)
            return window.filter { !($0.id.map(flagged.contains) ?? false) }
        } catch {
            AppLog.write("수문장 실패, 제안에 화면 기록을 쓰지 않음: \(error)")
            return []
        }
    }

    var sumunjangDetail: String {
        switch sumunjangDownload {
        case .downloading(let fraction) where settings.sumunjang: return tr("수문장 모델을 받고 있어요 (\(Int(fraction * 100))%)")
        case .failed where settings.sumunjang: return tr("모델을 받지 못했어요. 인터넷 연결을 확인해 주세요.")
        default: return tr("건강, 종교, 정치 성향 같은 민감정보가 보이는 화면은 AI에 보내지 않아요")
        }
    }

    var sumunjangNotes: [String] {
        guard settings.sumunjang else { return [] }
        switch sumunjangDownload {
        case .downloading: return [tr("다 받을 때까지 업무 정리를 미뤄요. 기록은 계속 남아요.")]
        case .failed: return [tr("받을 때까지 업무 정리를 미뤄요.")]
        case .idle: return []
        }
    }
}
