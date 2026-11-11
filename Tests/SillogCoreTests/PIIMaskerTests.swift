import XCTest
@testable import SillogCore

final class PIIMaskerTests: XCTestCase {
    func testMasksEachKind() {
        let cases: [(String, String)] = [
            ("주민번호 900101-1234567 입니다", "주민번호 [ID] 입니다"),
            ("연락처 010-1234-5678, 02-123-4567, +82 10-1234-5678", "연락처 [PHONE], [PHONE], [PHONE]"),
            ("메일 hong.gildong@example.co.kr 로", "메일 [EMAIL] 로"),
            ("카드 4111-1111-1111-1111 결제", "카드 [CARD] 결제"),
            ("국민 123456-01-234567 입금", "국민 [ACCOUNT] 입금"),
            ("OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwx", "OPENAI_API_KEY=[SECRET]"),
            ("password: hunter2hunter2", "password: [SECRET]"),
            ("ghp_abcdefghijklmnopqrstuvwxyz0123456789 pushed", "[SECRET] pushed"),
            ("SSN 123-45-6789 on file", "SSN [ID] on file"),
            ("マイナンバー 1234 5678 9018 です", "マイナンバー [ID] です"),
            ("SIN 046-454-286", "SIN [ID]"),
            ("NI number AB 12 34 56 C", "NI number [ID]"),
            ("codice RSSMRA85T10A562S", "codice [ID]"),
            ("DNI 12345678Z", "DNI [ID]"),
            ("IBAN GB82 WEST 1234 5698 7654 32", "IBAN [ACCOUNT]"),
            ("call +1 (415) 555-2671 or +44 20 7946 0958, 415-555-2671", "call [PHONE] or [PHONE], [PHONE]"),
            ("身份证 110105196108120398", "身份证 [ID]"),
            ("Aadhaar No. 607117605943 / 4660 8369 4614", "Aadhaar No. [ID] / [ID]"),
            ("PAN AUFPW1550A", "PAN [ID]"),
            ("HKID Z735035(0), 台灣 F263080999, NRIC G9635364U", "HKID [ID], 台灣 [ID], NRIC [ID]"),
            ("CURP REFC730426HGTHKV20", "CURP [ID]"),
            ("CPF 980.773.235-29.", "CPF [ID]."),
            ("NIR 1 83 05 69 813 768 79", "NIR [ID]"),
            ("Steuer-ID 34279682010, PESEL 58032479321", "Steuer-ID [ID], PESEL [ID]"),
            ("personnummer 800306-4378", "personnummer [ID]"),
            ("BSN 324191194, TFN: 405248346", "BSN [ID], TFN: [ID]"),
            ("amex 3784 245440 59153", "amex [CARD]"),
            ("Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345", "Authorization: Bearer [SECRET]"),
            ("번호는110105196108120398입니다", "번호는[ID]입니다"),
        ]
        for (input, expected) in cases { XCTAssertEqual(PIIMasker.mask(input), expected) }
    }

    func testMasksStreetAddress() throws {
        // NSDataDetector finds addresses by the system's region, and CI runners don't find Korean ones.
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "Address detection differs on CI")
        let masked = PIIMasker.mask("배송지는 서울특별시 강남구 테헤란로 152 입니다")
        XCTAssertTrue(masked.contains("[ADDRESS]"), masked)
        XCTAssertFalse(masked.contains("테헤란로"), masked)
    }

    func testSendsTextAsIsWhenOff() {
        PIIMasker.enabled = false
        defer { PIIMasker.enabled = true }
        XCTAssertEqual(PIIMasker.mask("전화 010-1234-5678"), "전화 010-1234-5678")
    }

    func testLeavesOrdinaryTextAlone() {
        let texts = [
            "[3] 2026-11-12 14:05 Xcode · PIIMasker.swift (dwell 320s)",
            "https://github.com/apple/swift/pull/12345 를 읽었다",
            "카드 번호 형식 1234-5678-9012-3456 은 검증에 실패한다",
            "token: 입력 토큰 수, version 1.2.3-beta",
            "row 12 of 240, 1731400000",
            "SSN 000-12-3456, 123456789012, 12345678A, GB00 WEST 1234 5698 7654 32",
            "ref 324191194 and 405248346, order 080196206870",
            "ISBN 89-1234-567-8, 사업자등록번호 123-45-67890",
            "0000000  7246 6565 5342 3a44 5420 6568 7020 776f",
            "id 12345678-1234-1234-9abc-def012345678",
            "192.168.0.1 at 14:05:33, build 2026.11.12, 3 - 5 items, pages 120-135",
            "commit 4f2a9c1 took 1,234 ms (p95 2.5 s) for 10 000 rows",
        ]
        for text in texts { XCTAssertEqual(PIIMasker.mask(text), text) }
    }
}
