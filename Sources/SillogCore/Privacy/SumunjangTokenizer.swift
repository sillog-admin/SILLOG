import Foundation

/// SUMUNJANG's BPE tokenizer, read from its tokenizer.json, cutting text as the Python tokenizer the model learned with.
/// Own code because the Swift tokenizer starts BPE from grapheme clusters, the Python one from code points,
/// so emoji such as ❤️ came out as bytes.
struct SumunjangTokenizer {
    private struct Merge { let rank: Int32, id: Int32 }

    private let scalars: [UInt32: Int32]
    private let merges: [Int64: Merge]
    private let byteIds: [Int32]
    private let added: NSRegularExpression
    private let addedIds: [String: Int32]
    private let pieces: [String]

    /// Args: file is a Hugging Face tokenizer.json with a BPE model and list-form merges.
    /// Raises: SumunjangError.model when the file has no such model; the file's read or JSON error otherwise.
    init(file: URL) throws {
        // JSONSerialization drops a U+FEFF that starts a string, and 8 tokens start with one;
        // they travel as U+10FFFD, which the vocabulary lacks. (JSONDecoder keeps it but merges NFC and NFD keys.)
        var data = try Data(contentsOf: file), from = data.startIndex
        while let found = data.range(of: Self.bom, in: from..<data.endIndex) {
            data.replaceSubrange(found, with: Self.stand)
            from = found.lowerBound + Self.stand.count
        }
        let root = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        guard let model = root?["model"] as? NSDictionary, let vocab = model["vocab"] as? NSDictionary,
              let merges = model["merges"] as? [Any], let added = root?["added_tokens"] as? [NSDictionary] else {
            throw SumunjangError.model("tokenizer.json has no BPE model")
        }
        // Keys are UTF-8 bytes: Swift String equality treats canonically equal tokens, such as NFC and NFD 가, as one.
        var ids: [[UInt8]: Int32] = [:], scalars: [UInt32: Int32] = [:], pieces: [Int: String] = [:]
        ids.reserveCapacity(vocab.count)
        for (key, value) in vocab {
            guard let key = key as? String, let id = (value as? NSNumber)?.int32Value else { continue }
            ids[Array(key.utf8)] = id
            pieces[Int(id)] = key.utf8.contains(Self.stand[0]) ? key.replacingOccurrences(of: "\u{10FFFD}", with: "\u{FEFF}") : key
            if key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first { scalars[scalar.value == 0x10FFFD ? 0xFEFF : scalar.value] = id }
        }
        var table: [Int64: Merge] = [:]
        table.reserveCapacity(merges.count)
        for (rank, merge) in merges.enumerated() {
            guard let pair = merge as? [String], pair.count == 2, let a = ids[Array(pair[0].utf8)], let b = ids[Array(pair[1].utf8)],
                  let ab = ids[Array(pair[0].utf8) + Array(pair[1].utf8)], table[Self.key(a, b)] == nil else { continue }
            table[Self.key(a, b)] = Merge(rank: Int32(rank), id: ab)
        }
        var addedIds: [String: Int32] = [:]
        for token in added {
            guard let content = token["content"] as? String, let id = (token["id"] as? NSNumber)?.int32Value else { continue }
            addedIds[content] = id
            pieces[Int(id)] = content
        }
        let unknown = ids[Array(((model["unk_token"] as? String) ?? "<unk>").utf8)] ?? 0
        self.scalars = scalars
        self.merges = table
        self.byteIds = (0..<256).map { ids[Array(String(format: "<0x%02X>", $0).utf8)] ?? unknown }
        // Longest first, so the regex takes the longest added token at each place, as the Python tokenizer does.
        let pattern = addedIds.keys.sorted { $0.utf16.count > $1.utf16.count }.map(NSRegularExpression.escapedPattern).joined(separator: "|")
        self.added = try NSRegularExpression(pattern: pattern.isEmpty ? "(?!)" : pattern)
        self.addedIds = addedIds
        self.pieces = (0...(pieces.keys.max() ?? -1)).map { pieces[$0] ?? "" }
    }

    /// Args: text is the text as the Python tokenizer gets it.
    /// Returns: its token ids, without <bos> and <eos>.
    func encode(_ text: String) -> [Int] {
        let source = text as NSString
        var out: [Int32] = [], at = 0
        // Metaspace, prepend_scheme always: each stretch between added tokens starts with "▁", and each "▁" starts a word.
        func section(upTo end: Int) {
            guard end > at else { return }
            let space: Unicode.Scalar = "▁"
            var word: [Int32] = []
            for (k, scalar) in source.substring(with: NSRange(location: at, length: end - at)).unicodeScalars.enumerated() {
                let scalar = scalar == " " ? space : scalar
                if k == 0, scalar != space { word.append(scalars[space.value] ?? byteIds[0]) }
                if scalar == space, !word.isEmpty { out += bpe(word); word = [] }
                if let id = scalars[scalar.value] { word.append(id) } else { word += String(scalar).utf8.map { byteIds[Int($0)] } }
            }
            out += bpe(word)
        }
        for match in added.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            section(upTo: match.range.location)
            if let id = addedIds[source.substring(with: match.range)] { out.append(id) }
            at = NSMaxRange(match.range)
        }
        section(upTo: source.length)
        return out.map(Int.init)
    }

    /// Returns: the vocabulary string of a token id, such as "▁예약" or "<0xF0>".
    func piece(_ id: Int) -> String? { pieces.indices.contains(id) ? pieces[id] : nil }

    /// Merges the lowest-ranked pair everywhere until no pair merges.
    private func bpe(_ word: [Int32]) -> [Int32] {
        var word = word
        while word.count > 1 {
            var best: Merge?, pair: Int64 = 0
            for k in 1..<word.count {
                let key = Self.key(word[k - 1], word[k])
                if let merge = merges[key], merge.rank < best?.rank ?? .max { best = merge; pair = key }
            }
            guard let best else { break }
            var merged: [Int32] = [], k = 0
            while k < word.count {
                if k + 1 < word.count, Self.key(word[k], word[k + 1]) == pair { merged.append(best.id); k += 2 } else { merged.append(word[k]); k += 1 }
            }
            word = merged
        }
        return word
    }

    private static let bom = Data([0xEF, 0xBB, 0xBF]), stand = Data("\u{10FFFD}".utf8)

    private static func key(_ a: Int32, _ b: Int32) -> Int64 { Int64(a) << 32 | Int64(UInt32(bitPattern: b)) }
}
