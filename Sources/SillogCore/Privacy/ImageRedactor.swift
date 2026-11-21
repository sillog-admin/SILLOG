import CoreGraphics
import Foundation
import Vision

/// Paints over the personal data that Vision reads in a screenshot, using the rules of `PIIMasker`, and over the faces it finds.
public enum ImageRedactor {
    public struct Failure: LocalizedError, CustomStringConvertible {
        public let detail: String
        public var errorDescription: String? { tr("화면 속 개인정보를 가리지 못해 잠시 뒤 다시 정리해요.") }
        public var description: String { "image redaction failed: \(detail)" }
    }

    /// Args: image is a screenshot bound for an external model.
    /// Returns: a copy with a black box over each match, or the image itself when masking is off or nothing matched.
    /// Raises: Failure when Vision cannot read the image, so the caller holds it back instead of sending it unread.
    public static func redact(_ image: CGImage) throws -> CGImage {
        guard PIIMasker.enabled else { return image }
        // Vision garbles small print and skips light text on a dark background, so it reads a 3x copy and its inverse; 4x read no better.
        // Some fonts read right only at their own size, such as the dates on a form, so the original is read too.
        // Gray copies made one at a time keep a single quarter-size 3x buffer alive.
        // A copy only helps where its text is dark on light, so a screen with no dark area skips the inverse and one with no light area skips the plain copy.
        var boxes = try piiBoxes(in: image)
        let tones = blockTones(image)
        if tones.light { boxes += try piiBoxes(in: draw(image, scale: 3, gray: true) { _, _ in }) }
        if tones.dark { boxes += try piiBoxes(in: draw(image, scale: 3, gray: true) { context, size in context.setBlendMode(.difference); context.setFillColor(gray: 1, alpha: 1); context.fill(size) }) }
        boxes += try faces(in: image)
        guard !boxes.isEmpty else { return image }
        return try draw(image) { context, _ in
            context.setFillColor(gray: 0, alpha: 1)
            // Vision and CGContext both put the origin at the bottom left.
            for box in boxes {
                let rect = VNImageRectForNormalizedRect(box, image.width, image.height)
                context.fill(rect.insetBy(dx: -rect.height * 0.2, dy: -rect.height * 0.2))
            }
        }
    }

    /// Returns: whether any 32px block of image is lighter than mid gray, and whether any is darker.
    static func blockTones(_ image: CGImage) -> (light: Bool, dark: Bool) {
        let width = max(1, image.width / 32), height = max(1, image.height / 32)
        var pixels = [UInt8](repeating: 0, count: width * height)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return (true, true) }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return (buffer.contains { $0 >= 128 }, buffer.contains { $0 < 128 })
        }
    }

    /// Returns: normalized boxes over each PIIMasker match in the text Vision reads.
    private static func piiBoxes(in image: CGImage) throws -> [CGRect] {
        let lines = try recognize(image)
        // One joined text, so a label on the line above still counts and a match that wraps is covered on both lines.
        var text = "", starts: [Int] = []
        for line in lines {
            starts.append(text.utf16.count)
            text += line.string + "\n"
        }
        var boxes: [CGRect] = []
        for match in PIIMasker.matches(in: text) {
            for (index, line) in lines.enumerated() {
                let hit = NSIntersectionRange(match.range, NSRange(location: starts[index], length: line.string.utf16.count))
                guard hit.length > 0,
                      var range = Range(NSRange(location: hit.location - starts[index], length: hit.length), in: line.string) else { continue }
                // The rules know the road and the unit, not every apartment or village name between and after them.
                if match.kind == .address { range = range.lowerBound..<line.string.endIndex }
                guard var box = try? line.boundingBox(for: range)?.boundingBox else { continue }
                // Vision can stop reading partway through a long unbroken line, so a secret that runs to the end of what it read may go on past it.
                if match.kind == .secret, !line.string[range.upperBound...].contains(where: \.isWhitespace) { box.size.width = 1 - box.minX }
                boxes.append(box)
            }
        }
        return boxes
    }

    private static func recognize(_ image: CGImage) throws -> [VNRecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = false
        // Seen failing with e5rt code 13 while macOS purged caches on a nearly full disk.
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { throw Failure(detail: "\(error)") }
        // Vision reads a table column by column, which puts a label far from its value, so lines go row by row, left to right.
        var rows: [[VNRecognizedTextObservation]] = []
        for line in (request.results ?? []).sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
            if let top = rows.last?.first, line.boundingBox.midY > top.boundingBox.minY { rows[rows.count - 1].append(line) } else { rows.append([line]) }
        }
        return rows.flatMap { $0.sorted { $0.boundingBox.minX < $1.boundingBox.minX } }.compactMap { $0.topCandidates(1).first }
    }

    /// Returns: normalized boxes over the faces in image, such as the photo on a résumé.
    private static func faces(in image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { throw Failure(detail: "\(error)") }
        return (request.results ?? []).map(\.boundingBox)
    }

    /// Returns: a copy of image with paint applied over it.
    private static func draw(_ image: CGImage, scale: Int = 1, gray: Bool = false, _ paint: (CGContext, CGRect) -> Void) throws -> CGImage {
        guard let space = gray ? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) : CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width * scale, height: image.height * scale, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure(detail: "no bitmap context") }
        context.interpolationQuality = .high
        let size = CGRect(x: 0, y: 0, width: image.width * scale, height: image.height * scale)
        context.draw(image, in: size)
        paint(context, size)
        guard let result = context.makeImage() else { throw Failure(detail: "no image from bitmap context") }
        return result
    }
}
