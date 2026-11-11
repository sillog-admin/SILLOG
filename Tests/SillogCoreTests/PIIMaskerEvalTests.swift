import XCTest
@testable import SillogCore

/// Writes the masker's matches for an evaluation corpus so `scripts/pii-eval/pii_eval.py` can score them.
final class PIIMaskerEvalTests: XCTestCase {
    func testDumpMatchesForEvaluation() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["SILLOG_PII_EVAL_IN"], let output = environment["SILLOG_PII_EVAL_OUT"] else {
            throw XCTSkip("Set SILLOG_PII_EVAL_IN and SILLOG_PII_EVAL_OUT to run the evaluation.")
        }
        var lines: [String] = []
        for line in try String(contentsOfFile: input, encoding: .utf8).split(separator: "\n") {
            let item = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let text = try XCTUnwrap(item["text"] as? String)
            // Offsets are UTF-16 units.
            let matches = PIIMasker.matches(in: text).map {
                ["start": $0.range.location, "end": $0.range.location + $0.range.length, "kind": $0.kind.rawValue, "rule": $0.rule] as [String: Any]
            }
            let data = try JSONSerialization.data(withJSONObject: ["id": item["id"] ?? "", "matches": matches])
            lines.append(String(decoding: data, as: UTF8.self))
        }
        try lines.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
    }
}
