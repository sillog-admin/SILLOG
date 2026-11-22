import AppKit
import Vision
import XCTest
@testable import SillogCore

final class ImageRedactorTests: XCTestCase {
    func testPaintsOverPersonalDataAndKeepsTheRest() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "OCR differs on CI")
        let image = try XCTUnwrap(render(["회의 메모 Quarterly planning", "연락처 010-1234-5678", "메일 hong.gildong@example.co.kr"]))
        let before = try read(image)
        XCTAssertTrue(before.contains("5678"), before)

        let after = try read(try redact(image))
        XCTAssertTrue(after.contains("Quarterly"), after)
        XCTAssertFalse(after.contains("5678"), after)
        XCTAssertFalse(after.contains("example"), after)
    }

    func testSecretAtTheEndOfALineIsCoveredToTheRightEdge() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "OCR differs on CI")
        let image = try XCTUnwrap(render(["OPENAI_API_KEY=sk-proj-AbCdEf1234567890GhIjKlMnOp", "연락처 010-1234-5678"]))
        let after = try redact(image)
        // render puts line n at y = height - 80 * (n + 1), counted from the bottom.
        XCTAssertEqual(gray(after, x: after.width - 4, y: after.height - 80 + 12), 0, "the secret line is covered to the edge")
        XCTAssertEqual(gray(after, x: after.width - 4, y: after.height - 160 + 12), 255, "the phone line is covered only over the number")
    }

    private func gray(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        var pixel: UInt8 = 0
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        context.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
        return pixel
    }

    func testLightTextOnADarkBackgroundIsCovered() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "OCR differs on CI")
        let image = try XCTUnwrap(render(["결제 카드 4111 1111 1111 1111 승인", "배송지 서울특별시 강남구 테헤란로 123, 4층입니다"], dark: true))
        let after = try read(try redact(image))
        XCTAssertFalse(after.contains("4111"), after)
        XCTAssertFalse(after.contains("테헤란로"), after)
    }

    func testASmallDarkPanelOnALightScreenCountsAsDark() throws {
        func screen(_ background: CGFloat, panel: CGFloat?) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: 1400, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(gray: background, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 1400, height: 500))
            // A tooltip only 40px tall, about one block row.
            if let panel { context.setFillColor(gray: panel, alpha: 1); context.fill(CGRect(x: 40, y: 200, width: 420, height: 40)) }
            return try XCTUnwrap(context.makeImage())
        }
        XCTAssertTrue(ImageRedactor.blockTones(try screen(1, panel: nil)) == (true, false))
        XCTAssertTrue(ImageRedactor.blockTones(try screen(1, panel: 0.1)) == (true, true))
        XCTAssertTrue(ImageRedactor.blockTones(try screen(0.12, panel: nil)) == (false, true))
    }

    func testFormValuesInTheirOwnColumnAreCovered() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "OCR differs on CI")
        let rows = [("성명", "홍길동"), ("휴대전화", "직접 입력"), ("생년월일", "1990-03-15"), ("성별", "남"), ("주소", "서울특별시 강남구 테헤란로 123 역삼동 한빛마을 101동 1001호")]
        let width = 1400, height = 70 * rows.count + 40
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        // A label column with its own shading, as on a printed form.
        for (index, (label, value)) in rows.enumerated() {
            let y = height - 70 * (index + 1)
            context.setFillColor(gray: 0.95, alpha: 1)
            context.fill(CGRect(x: 20, y: y - 18, width: 200, height: 66))
            NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.darkGray]).draw(at: CGPoint(x: 80, y: y))
            NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black]).draw(at: CGPoint(x: 260, y: y))
        }
        NSGraphicsContext.current = nil
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertTrue(try read(image).contains("1990"))

        let after = try read(try redact(image))
        XCTAssertFalse(after.contains("1990"), after)
        XCTAssertFalse(after.contains("한빛"), "the rest of an address line is covered: \(after)")
        XCTAssertTrue(after.contains("직접 입력"), after)
    }

    private func render(_ lines: [String], dark: Bool = false) -> CGImage? {
        let width = 1200, height = 80 * lines.count + 40
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(gray: dark ? 0.12 : 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (index, line) in lines.enumerated() {
            NSAttributedString(string: line, attributes: [.font: dark ? NSFont.monospacedSystemFont(ofSize: 16, weight: .regular) : NSFont.systemFont(ofSize: 32),
                                                          .foregroundColor: dark ? NSColor(white: 0.85, alpha: 1) : NSColor.black])
                .draw(at: CGPoint(x: 40, y: height - 80 * (index + 1)))
        }
        NSGraphicsContext.current = nil
        return context.makeImage()
    }

    // Vision fails with e5rt code 13 while macOS purges caches on a nearly full disk; that says nothing about the redactor.
    private func redact(_ image: CGImage) throws -> CGImage {
        do { return try ImageRedactor.redact(image) } catch let error as ImageRedactor.Failure where error.detail.contains("e5rt") { throw XCTSkip(error.detail) }
    }

    private func read(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch where "\(error)".contains("e5rt") { throw XCTSkip("\(error)") }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
