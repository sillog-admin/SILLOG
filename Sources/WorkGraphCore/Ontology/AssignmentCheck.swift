import Foundation

/// 앱이 판정을 반영하기 전에 하는 검증을, 후보 업무만 넣은 빈 그래프에 적용해 본다 (측정용, 아무것도 기록하지 않음)
public enum AssignmentCheck {
    /// 앱이 이 판정을 거부하면 그 이유, 받아들이면 nil
    public static func rejection(_ patch: AssignmentPatch, rows: [ActivityRow], openTasks: [TaskDigest], now: Double) -> String? {
        do {
            let db = try WGDatabase.inMemory()
            try db.writer.write { conn in
                let tx = GraphTx(conn)
                try TBox.seed(tx, at: 0)
                for task in openTasks {
                    _ = try tx.upsertNode(label: NodeLabel.task, key: task.id, subtype: nil, title: task.title, props: ["status": "active"], at: 0)
                }
                _ = try AssignmentApplier().apply(patch, rows: rows, tx: tx, now: now, requireComplete: true)
            }
            return nil
        } catch {
            return "\(error)"
        }
    }
}
