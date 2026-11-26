import CoreML
import Foundation
import WhisperKit

/// Downloads SUMUNJANG from Hugging Face once and scores screen records with Core ML on this Mac.
/// Loaded on use and dropped after `idleSeconds`, so the menu bar app does not hold about 680 MB all day.
public actor SumunjangModel {
    public static let shared = SumunjangModel(folder: downloadBase.appendingPathComponent("models/\(repo)", isDirectory: true))
    static let repo = "beaver-zip/sumunjang"
    // Pinned so a later upload never changes what a build scores with.
    static let revision = "bb76c18c698dbfe09d6771dfd5f0ca1250785910"
    static let idleSeconds: Double = 90

    /// Where Whisper's models also go: the data folder's models.
    static var downloadBase: URL { SillogDatabase.defaultDirectory().appendingPathComponent("models", isDirectory: true) }

    /// What `scripts/sumunjang/convert.py` writes to sumunjang.json.
    struct Config: Decodable {
        let maxLen, overlap, margin, sepId, padId: Int
        let headIds: [Int]
        let maskToken: String

        enum CodingKeys: String, CodingKey {
            case overlap, margin
            case maxLen = "max_len", sepId = "sep_id", padId = "pad_id", headIds = "head_ids", maskToken = "mask_token"
        }
    }

    private struct Loaded: @unchecked Sendable {
        let model: MLModel
        let tokenizer: SumunjangTokenizer
        let config: Config
    }

    public let folder: URL
    private var loading: Task<Loaded, Error>?
    private var unloader: Task<Void, Never>?

    /// Args: folder holds sumunjang.json, tokenizer/ and coreml/Sumunjang.mlpackage, as the Hugging Face repo does.
    public init(folder: URL) { self.folder = folder }

    private nonisolated var compiled: URL { folder.appendingPathComponent("Sumunjang-\(Self.revision.prefix(12)).mlmodelc", isDirectory: true) }

    /// Returns: true when this build's model is on disk, so scoring needs no network.
    public nonisolated var isReady: Bool { FileManager.default.fileExists(atPath: compiled.path) }

    /// Args: progress gets 0...1 while the files arrive.
    /// Raises: SumunjangError.download when a file cannot be fetched or the Core ML model cannot be compiled.
    public func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !isReady else { return }
        do {
            // Hub progress counts files, and the weights are 95% of the bytes, so they come alone and fill the bar.
            let hub = HubApiWrapper(downloadBase: Self.downloadBase), repo = HubApiWrapper.Repo(id: Self.repo)
            _ = try await hub.snapshot(from: repo, revision: Self.revision, matching: ["sumunjang.json", "tokenizer/*", "coreml/*.json", "coreml/*.mlmodel"]) {
                progress(0.05 * $0.fractionCompleted)
            }
            _ = try await hub.snapshot(from: repo, revision: Self.revision, matching: ["coreml/*.bin"]) { progress(0.05 + 0.95 * $0.fractionCompleted) }
            try await compile()
            // The compiled copy is all scoring reads; the package would double the disk use.
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("coreml", isDirectory: true))
        } catch {
            throw SumunjangError.download("\(error)")
        }
    }

    /// Compiles coreml/Sumunjang.mlpackage once; the app keeps only the compiled copy's path in mind.
    /// Raises: Core ML's error when the package is missing or does not compile.
    public func compile() async throws {
        guard !isReady else { return }
        let temp = try await MLModel.compileModel(at: folder.appendingPathComponent("coreml/Sumunjang.mlpackage"))
        try? FileManager.default.removeItem(at: compiled)
        try FileManager.default.moveItem(at: temp, to: compiled)
    }

    /// Args: records are masked screen records.
    /// Returns: one score per record, the highest 1 - P(none) over its windows.
    /// Raises: SumunjangError.notReady before the download finishes, .model when the tokenizer or Core ML fails.
    public func scores(_ records: [Sumunjang.Record]) async throws -> [Double] {
        let loaded = try await load()
        defer { touched() }
        let encode = { (text: String) in Self.encode(text, loaded) }
        let piece = { (id: Int) in loaded.tokenizer.piece(id) }
        return try records.map { record in
            try Self.windows(record, config: loaded.config, encode: encode, piece: piece)
                .map { 1 - (try Self.probabilities($0, loaded))[0] }.max() ?? 0
        }
    }

    /// Args: record is a masked screen record.
    /// Returns: its model inputs, one per window, for comparing with the Python scorer.
    /// Raises: SumunjangError like `scores`.
    public func inputs(_ record: Sumunjang.Record) async throws -> [[Int]] {
        let loaded = try await load()
        return Self.windows(record, config: loaded.config, encode: { Self.encode($0, loaded) }, piece: { loaded.tokenizer.piece($0) })
    }

    private func load() async throws -> Loaded {
        if let loading { return try await loading.value }
        guard isReady else { throw SumunjangError.notReady }
        let (folder, compiled) = (folder, compiled)
        let task = Task {
            do {
                let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: folder.appendingPathComponent("sumunjang.json")))
                let tokenizer = try SumunjangTokenizer(file: folder.appendingPathComponent("tokenizer/tokenizer.json"))
                // On 500 records the GPU stays within 0.011 of PyTorch; the Neural Engine drifts 0.04, the CPU 0.15.
                let units = MLModelConfiguration()
                units.computeUnits = .cpuAndGPU
                return Loaded(model: try MLModel(contentsOf: compiled, configuration: units), tokenizer: tokenizer, config: config)
            } catch {
                throw SumunjangError.model("\(error)")
            }
        }
        loading = task
        do { return try await task.value } catch { loading = nil; throw error }
    }

    private func touched() {
        unloader?.cancel()
        unloader = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.idleSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.unload()
        }
    }

    private func unload() { loading = nil }

    private static func encode(_ text: String, _ loaded: Loaded) -> [Int] {
        loaded.tokenizer.encode(text.replacingOccurrences(of: loaded.config.maskToken, with: " "))
    }

    /// Args: record is a masked screen record; encode tokenizes like the Python tokenizer; piece gives a token id's vocabulary string.
    /// Returns: the model inputs for the record, head + header and a slice of its text + separator,
    ///   cut as `Scorer.windows` in scripts/sumunjang/convert.py cuts them.
    static func windows(_ record: Sumunjang.Record, config: Config, encode: (String) -> [Int], piece: (Int) -> String?) -> [[Int]] {
        let room = config.maxLen - config.headIds.count - 1
        func sequence(_ state: String) -> [Int] { config.headIds + encode(state).prefix(room) + [config.sepId] }
        let text = record.text.replacingOccurrences(of: "{n}", with: "3").replacingOccurrences(of: config.maskToken, with: " ")
        let header = header(record)
        let ids = encode(text)
        guard !text.isEmpty, !ids.isEmpty else { return [sequence(header)] }
        let budget = max(64, room - encode(header).count - config.margin), stride = max(16, budget - config.overlap)
        // Python cuts the text by each token's character span. The spans come from the vocabulary strings: "▁" is a
        // space, "<0xAB>" one UTF-8 byte. A leading "▁" with no space under it is one the tokenizer put before a section;
        // on its own it spans the section's first character, as the Python offsets have it.
        let bytes = Array(text.utf8)
        func charLength(_ at: Int) -> Int {
            guard at < bytes.count else { return 0 }
            return bytes[at] < 0x80 ? 1 : bytes[at] < 0xE0 ? 2 : bytes[at] < 0xF0 ? 3 : 4
        }
        var starts: [Int] = [], ends: [Int] = [], at = 0
        for id in ids {
            let token = piece(id) ?? ""
            var length = token.count == 6 && token.hasPrefix("<0x") ? 1 : token.replacingOccurrences(of: "▁", with: " ").utf8.count
            starts.append(at)
            if token.hasPrefix("▁"), at >= bytes.count || bytes[at] != 0x20 {
                if token == "▁" { ends.append(at + charLength(at)); continue }
                length -= 1
            }
            at += length
            ends.append(at)
        }
        // Clamped: an unknown piece would shift the spans a little, never past the text.
        func isCharStart(_ i: Int) -> Bool { i <= 0 || i >= bytes.count || bytes[i] & 0xC0 != 0x80 }
        var out: [[Int]] = [], i = 0
        while true {
            let j = min(ids.count, i + budget)
            var from = min(bytes.count, max(0, starts[i])), to = min(bytes.count, max(from, ends[j - 1]))
            while !isCharStart(from) { from -= 1 }
            while !isCharStart(to) { to += 1 }
            out.append(sequence(header + String(decoding: bytes[from..<to], as: UTF8.self)))
            if j >= ids.count { return out }
            i += stride
        }
    }

    static func header(_ record: Sumunjang.Record) -> String {
        func trunc(_ s: String, _ n: Int) -> String {
            let s = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            // Python counts code points.
            return s.unicodeScalars.count <= n ? s : String(String.UnicodeScalarView(s.unicodeScalars.prefix(n - 1))) + "…"
        }
        func or(_ s: String) -> String { s.isEmpty ? "-" : s }
        var parts = ["[앱] \(or(record.app)) (\(or(record.appKind)), \(or(record.captureSource)))"]
        for (value, label) in [(record.windowTitle, "[창] "), (record.url, "[URL] "), (record.docPath, "[경로] ")] {
            if let value, !value.isEmpty { parts.append(label + trunc(value, 120)) }
        }
        return parts.joined(separator: "\n") + "\n[화면]\n"
    }

    private static func probabilities(_ sequence: [Int], _ loaded: Loaded) throws -> [Double] {
        let n = loaded.config.maxLen
        do {
            let ids = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
            let mask = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
            for k in 0..<n {
                ids[k] = NSNumber(value: k < sequence.count ? sequence[k] : loaded.config.padId)
                mask[k] = NSNumber(value: k < sequence.count ? 1 : 0)
            }
            let out = try loaded.model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "attention_mask": mask]))
            guard let probs = out.featureValue(for: "probs")?.multiArrayValue else { throw SumunjangError.model("no probs output") }
            return (0..<probs.count).map { probs[$0].doubleValue }
        } catch let error as SumunjangError {
            throw error
        } catch {
            throw SumunjangError.model("\(error)")
        }
    }
}
