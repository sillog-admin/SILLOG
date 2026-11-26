import GRDB
import XCTest
@testable import SillogCore

final class SumunjangTests: XCTestCase {
    /// The model learned from text masked with Korean placeholders, so it gets them even when the setting is off.
    func testMasksWithTheTrainingPlaceholdersEvenWhenMaskingIsOff() {
        PIIMasker.enabled = false
        defer { PIIMasker.enabled = true }
        XCTAssertEqual(Sumunjang.masked("전화 010-1234-5678, kim@example.com, /Users/somebody/메모.txt"),
                       "전화 [전화번호], [이메일], /Users/[사용자]/메모.txt")
        XCTAssertEqual(Sumunjang.masked("주민번호 900101-1234567"), "주민번호 [주민번호]")
        XCTAssertEqual(Sumunjang.masked("배송지는 서울특별시 강남구 테헤란로 152 입니다, cc @jiho_lee, ssh ubuntu@52.78.12.34"),
                       "배송지는 [주소] 입니다, cc [계정], ssh ubuntu@[IP주소]")
        let path = Sumunjang.masked("/Users/x/Documents/주민등록번호 9001011234567 사본.pdf".decomposedStringWithCanonicalMapping)
        XCTAssertEqual(Array(path.unicodeScalars), Array("/Users/[사용자]/Documents/주민등록번호 [주민번호] 사본.pdf".unicodeScalars))
    }

    /// A new masker rule without a placeholder here would reach the model as [식별번호], which it learned only for foreign IDs.
    func testEveryKoreanAndContactRuleHasATrainingPlaceholder() {
        let foreignIDs: Set = ["us-ssn", "cn-ric", "jp-mynumber", "in-aadhaar", "in-pan", "hk-hkid", "tw-id", "sg-nric", "ca-sin", "mx-curp",
                               "br-cpf", "gb-nino", "fr-nir", "it-cf", "es-dni", "de-idnr", "pl-pesel", "se-pnr", "au-tfn", "nl-bsn"]
        XCTAssertEqual(Set(PIIMasker.rules.map(\.name)).subtracting(Sumunjang.tags.keys).subtracting(foreignIDs), [])
    }

    /// Windows repeat the header and cut the text where the Python scorer cuts it: by the characters each token covers.
    func testWindowsRepeatTheHeaderAndOverlap() throws {
        // One token per character, a space joined to the next character as "▁", like the real tokenizer's pieces.
        var vocab: [String: Int] = [:], pieces: [String] = []
        func id(_ piece: String) -> Int {
            if let id = vocab[piece] { return id }
            vocab[piece] = pieces.count; pieces.append(piece)
            return pieces.count - 1
        }
        func encode(_ text: String) -> [Int] {
            var out: [Int] = [], pending = ""
            for char in text.hasPrefix(" ") ? text : " " + text {
                if char == " " { if !pending.isEmpty { out.append(id(pending)) }; pending = "▁"; continue }
                out.append(id(pending + String(char))); pending = ""
            }
            return pending.isEmpty ? out : out + [id(pending)]
        }
        let config = SumunjangModel.Config(maxLen: 512, overlap: 64, margin: 6, sepId: -2, padId: -3, headIds: Array(repeating: -1, count: 10), maskToken: "<mask>")
        let text = String((0..<1000).map { i in Array("가나다라마바사")[i % 7] })
        let record = Sumunjang.Record(app: "Safari", appKind: "browser", captureSource: "ocr", windowTitle: "진료\n예약", url: nil, docPath: nil, text: text)

        let windows = SumunjangModel.windows(record, config: config, encode: encode, piece: { pieces[$0] })

        let header = "[앱] Safari (browser, ocr)\n[창] 진료 예약\n[화면]\n"
        XCTAssertEqual(SumunjangModel.header(record), header)
        let budget = 501 - encode(header).count - 6, stride = budget - 64
        XCTAssertEqual(windows.count, 3)
        for (k, window) in windows.enumerated() {
            XCTAssertEqual(Array(window.prefix(10)), config.headIds)
            XCTAssertEqual(window.last, config.sepId)
            let state = window.dropFirst(10).dropLast().map { pieces[$0] }.joined().replacingOccurrences(of: "▁", with: " ")
            let start = k * stride
            XCTAssertEqual(state, " " + header + String(Array(text)[start..<min(1000, start + budget)]), "window \(k)")
        }
    }

    /// Like the Python tokenizer: BPE from code points, so 🏳️‍🌈 keeps its pieces, NFD 가 stays apart from NFC 가,
    /// a token may start with U+FEFF, and every stretch between added tokens starts with "▁".
    func testTokenizerWorksOnCodePointsLikePython() throws {
        let bom = "\u{FEFF}"
        let json = #"""
        {"added_tokens": [{"id": 0, "content": "\n"}],
         "model": {"unk_token": "<unk>",
                   "vocab": {"\n": 0, "▁": 1, "a": 2, "b": 3, "▁a": 4, "ab": 5, "\ud83c\udff3": 6, "\ufe0f": 7, "\u200d": 8, "\ud83c\udf08": 9,
                             "<0xC3>": 10, "<0xA9>": 11, "<unk>": 12, "\uac00": 13, "\u1100": 14, "\u1161": 15, "\u1100\u1161": 16,
                             "#": 17, "\#(bom)": 18, "\#(bom)#": 19},
                   "merges": [["▁", "a"], ["a", "b"], ["\u1100", "\u1161"], ["\#(bom)", "#"]]}}
        """#
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sumunjang-tokenizer-\(UUID()).json")
        try Data(json.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let tokenizer = try SumunjangTokenizer(file: file)

        XCTAssertEqual(tokenizer.encode("ab\n\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}\u{E9}"), [4, 3, 0, 1, 6, 7, 8, 9, 10, 11])
        XCTAssertEqual(tokenizer.encode(" a b"), [4, 1, 3])
        XCTAssertEqual(tokenizer.encode("\u{AC00}"), [1, 13])
        XCTAssertEqual(tokenizer.encode("\u{1100}\u{1161}"), [1, 16])
        XCTAssertEqual(tokenizer.encode("#\u{FEFF}#"), [1, 17, 19])
        XCTAssertEqual(tokenizer.piece(19).map { Array($0.unicodeScalars) }, ["\u{FEFF}", "#"])
        XCTAssertEqual(tokenizer.encode(""), [])
    }

    func testSensitiveRowReachesTheModelWithoutItsContentAndChatSearchSkipsIt() async throws {
        let db = try SillogDatabase.inMemory()
        let store = EventStore(db)
        let clinic = try store.insert(Observation(ts: 100, trigger: "app_activate", appBundle: "com.google.Chrome", appName: "Google Chrome",
                                                  windowTitle: "진료 예약 확인", url: "https://hospital.example/booking"))
        try store.attach(observationId: clinic, textId: try store.upsertText("정신건강의학과 우울증 재진 예약", source: "ax", at: 100), screenshotPath: nil)
        let code = try store.insert(Observation(ts: 200, trigger: "app_activate", appBundle: "com.apple.Terminal", appName: "Terminal", windowTitle: "npm run dev"))
        let scored = Scored()
        let filter = Sumunjang { records in
            scored.add(records)
            return records.map { $0.text.contains("우울증") ? 0.95 : 0.02 }
        }
        let llm = StubLLM([.success(#"{"tasks":[{"ref":"A","match":"new","title":"개발 서버","task_type":"코드작성"}],"rows":[{"rows":"1-2","task":"A"}],"work":[]}"#)])
        let batcher = OntologyBatcher(db: db, llm: llm, config: .singleCall, home: "/Users/me", fileExists: { _ in false }, clock: { 500 })
        await batcher.setSumunjang(filter)

        let outcome = await batcher.runIfDue(force: true)

        guard case .ok = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(scored.records.count, 2)
        XCTAssertEqual(scored.records.first?.appKind, "browser")
        XCTAssertTrue(llm.lastUser.contains(Sumunjang.placeholder))
        for leak in ["진료", "hospital.example", "우울증"] { XCTAssertFalse(llm.lastUser.contains(leak), leak) }
        XCTAssertTrue(llm.lastUser.contains("npm run dev"))
        let flags = try await db.writer.read { try Int.fetchAll($0, sql: "SELECT sensitive FROM observations WHERE id IN (?, ?) ORDER BY id", arguments: [clinic, code]) }
        XCTAssertEqual(flags, [1, 0])
        XCTAssertFalse(try ContextSearch(db).search(query: "우울증").contains { $0.id == "observation:\(clinic)" })
        XCTAssertTrue(try ContextSearch(db).read("observation:\(clinic)").isEmpty)
        let ledger = try await db.writer.read { try LedgerBuilder().compute($0, days: [PeriodCalendar().day(100)]) }
        XCTAssertFalse(ledger.isEmpty)
        XCTAssertFalse(ledger.contains { $0.target.contains("hospital") }, "\(ledger)")
    }

    /// A periodic row repeats the screen without its own text; scoring it as empty would let a long sensitive screen through.
    func testPeriodicRowIsScoredWithTheLastTextOfItsWindow() async throws {
        let db = try SillogDatabase.inMemory()
        let store = EventStore(db)
        let first = try store.insert(Observation(ts: 100, trigger: "app_activate", appBundle: "com.google.Chrome", appName: "Google Chrome", windowTitle: "진료 예약"))
        try store.attach(observationId: first, textId: try store.upsertText("우울증 재진 예약", source: "ocr", at: 100), screenshotPath: nil)
        let later = try store.insert(Observation(ts: 160, trigger: "periodic", appBundle: "com.google.Chrome", appName: "Google Chrome", windowTitle: "진료 예약"))
        let fetched = try await db.writer.read { try Observation.fetchOne($0, key: later) }
        let observation = try XCTUnwrap(fetched)
        let scored = Scored()

        let flagged = try await Sumunjang { scored.add($0); return [0.9] }.sensitiveIDs([observation], db: db)

        XCTAssertEqual(flagged, [later])
        XCTAssertEqual(scored.records.first?.text, "우울증 재진 예약")
        XCTAssertEqual(scored.records.first?.captureSource, "ocr")
    }

    /// Before the model is downloaded nothing is sent, and the wait is not recorded as a failed batch.
    func testBatchWaitsForTheModelWithoutSendingOrFailing() async throws {
        let db = try SillogDatabase.inMemory()
        _ = try EventStore(db).insert(Observation(ts: 100, trigger: "app_activate", appBundle: "com.apple.Terminal", appName: "Terminal", windowTitle: "npm run dev"))
        let llm = StubLLM([])
        let batcher = OntologyBatcher(db: db, llm: llm, config: .singleCall, home: "/Users/me", fileExists: { _ in false }, clock: { 500 })
        await batcher.setSumunjang(Sumunjang { _ in throw SumunjangError.notReady })

        guard case .skipped = await batcher.runIfDue(force: true) else { return XCTFail("the batch must wait for the model") }
        XCTAssertEqual(llm.calls, 0)
        XCTAssertEqual(try EventStore(db).unprocessed(limit: 10).count, 1)
        let batches = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM batches") }
        XCTAssertEqual(batches, 0)

        await batcher.setSumunjang(Sumunjang { _ in throw SumunjangError.model("broken") })
        guard case .failed = await batcher.runIfDue(force: true) else { return XCTFail("a model that cannot run fails the batch") }
        XCTAssertEqual(llm.calls, 0)
        XCTAssertEqual(try EventStore(db).unprocessed(limit: 10).count, 1)
    }
}

private final class Scored: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Sumunjang.Record] = []
    var records: [Sumunjang.Record] { lock.lock(); defer { lock.unlock() }; return all }
    func add(_ more: [Sumunjang.Record]) { lock.lock(); all += more; lock.unlock() }
}
