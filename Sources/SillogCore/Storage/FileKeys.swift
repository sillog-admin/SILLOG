import Foundation
import GRDB

/// File keys are stored with composed Hangul so one path is one node.
enum FileKeys {
    static func composed(_ text: String) -> String { text.precomposedStringWithCanonicalMapping }
    // Swift compares strings canonically, so decomposed text only shows up in the bytes
    static func isDecomposed(_ text: String) -> Bool { !text.utf8.elementsEqual(composed(text).utf8) }

    /// Rewrites decomposed file keys already stored, folding a node into its composed twin.
    /// Args: conn is an open write transaction.
    /// Raises: database errors.
    static func composeStored(_ conn: Database) throws {
        let tx = GraphTx(conn)
        for row in try Row.fetchAll(conn, sql: "SELECT id, label, key FROM nodes WHERE key LIKE 'file:%'") {
            let id: Int64 = row["id"], label: String = row["label"], key: String = row["key"]
            guard isDecomposed(key) else { continue }
            if let twin = try tx.node(label: label, key: composed(key)) {
                try WeeklyReview.moveEdges(from: id, to: twin.id, conn: conn)
                try conn.execute(sql: "DELETE FROM nodes WHERE id = ?", arguments: [id])
            } else {
                try conn.execute(sql: "UPDATE nodes SET key = ? WHERE id = ?", arguments: [composed(key), id])
            }
        }

        for key in try String.fetchAll(conn, sql: "SELECT DISTINCT target_key FROM usage_ledger WHERE target_key LIKE 'file:%'") where isDecomposed(key) {
            try conn.execute(sql: """
                INSERT INTO usage_ledger(day, task_key, target_kind, target_key, seconds, first_at, last_at, hits, frozen)
                SELECT day, task_key, target_kind, ?, seconds, first_at, last_at, hits, frozen FROM usage_ledger WHERE target_key = ?
                ON CONFLICT(day, task_key, target_kind, target_key) DO UPDATE SET
                  seconds = usage_ledger.seconds + excluded.seconds, first_at = MIN(usage_ledger.first_at, excluded.first_at),
                  last_at = MAX(usage_ledger.last_at, excluded.last_at), hits = usage_ledger.hits + excluded.hits,
                  frozen = MAX(usage_ledger.frozen, excluded.frozen)
                """, arguments: [composed(key), key])
            try conn.execute(sql: "DELETE FROM usage_ledger WHERE target_key = ?", arguments: [key])
        }

        for id in try Int64.fetchAll(conn, sql: "SELECT id FROM nodes WHERE label = ? AND json_type(props, '$.project_seconds') = 'object'",
                                     arguments: [NodeLabel.task]) {
            let entries = try Row.fetchAll(conn, sql: "SELECT key, value FROM json_each((SELECT props FROM nodes WHERE id = ?), '$.project_seconds')",
                                           arguments: [id])
            guard entries.contains(where: { isDecomposed($0["key"]) }) else { continue }
            var tally: [String: Double] = [:]
            for entry in entries { tally[composed(entry["key"]), default: 0] += entry["value"] ?? 0 }
            let json = String(decoding: try JSONEncoder().encode(tally), as: UTF8.self)
            try conn.execute(sql: "UPDATE nodes SET props = json_set(props, '$.project_seconds', json(?)) WHERE id = ?", arguments: [json, id])
        }

        for row in try Row.fetchAll(conn, sql: "SELECT id, structured, metrics, anchors FROM digests WHERE structured || metrics || anchors LIKE '%file:%'") {
            for column in ["structured", "metrics", "anchors"] {
                let text: String = row[column]
                guard isDecomposed(text) else { continue }
                try conn.execute(sql: "UPDATE digests SET \(column) = ? WHERE id = ?", arguments: [composed(text), row["id"] as Int64])
            }
        }
    }
}
