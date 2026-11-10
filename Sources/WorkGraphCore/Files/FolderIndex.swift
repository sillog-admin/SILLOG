import Foundation

/// 사용자 폴더 구조의 색인. 폴더 제안 후보를 고르는 데 쓴다.
/// 이름이 아니라 "무엇이 들어 있나"를 함께 보므로, 폴더 이름이 "새 폴더 3" 이어도 안에 강의 PDF 가 있으면 후보가 된다.
public struct FolderIndex: Sendable {
    public struct Folder: Equatable, Sendable {
        public let path: String
        public let relativePath: String       // ~/... 표기
        public let name: String
        public let depth: Int
        public let fileCount: Int
        public let sampleFiles: [String]      // 최근 파일 이름 최대 6개
        public let modifiedAt: Double
    }

    public static let skipNames: Set<String> = [
        "node_modules", ".git", ".build", "build", "DerivedData", "Library", "Applications", "Pods", "venv", ".venv", "__pycache__",
        "target", "dist", ".Trash", "Movies", "Music", "Pictures", "Public",
    ]

    public let folders: [Folder]
    public let scannedAt: Double

    public init(folders: [Folder], scannedAt: Double = Date().timeIntervalSince1970) { self.folders = folders; self.scannedAt = scannedAt }

    /// roots 아래를 maxDepth 까지 훑는다. 숨김 폴더, 빌드 산출물, 시스템 폴더는 건너뛴다.
    /// 이 파일이 있으면 코드 저장소로 본다
    public static let projectMarkers: Set<String> = [".git", "Package.swift", "package.json", "Cargo.toml", "pyproject.toml", "go.mod", "pom.xml", "build.gradle", "Gemfile"]

    public static func scan(roots: [String], home: String, maxDepth: Int = 4, maxFolders: Int = 3_000) -> FolderIndex {
        var result: [Folder] = []
        let fm = FileManager.default
        func visit(_ path: String, depth: Int) {
            guard result.count < maxFolders, depth <= maxDepth else { return }
            guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return }
            // 코드 저장소는 그 자체를 후보로 남기고 안으로는 들어가지 않는다 (Sources, tests, docs 는 내려받은 파일을 두는 곳이 아니다)
            let isProject = entries.contains { projectMarkers.contains($0) }
            var files: [(String, Double)] = [], subdirs: [String] = []
            for entry in entries where !entry.hasPrefix(".") {
                let full = (path as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    if !isProject, !skipNames.contains(entry), !entry.hasSuffix(".app"), !entry.hasSuffix(".xcodeproj"), !entry.hasSuffix(".photoslibrary") { subdirs.append(full) }
                } else {
                    let modified = (try? fm.attributesOfItem(atPath: full)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    files.append((entry, modified))
                }
            }
            let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let samples = files.sorted { $0.1 > $1.1 }.prefix(6).map(\.0)
            result.append(Folder(path: path, relativePath: URINormalizer.normalize(filePath: path, home: home).replacingOccurrences(of: "file:", with: ""),
                                 name: (path as NSString).lastPathComponent, depth: depth, fileCount: files.count, sampleFiles: samples, modifiedAt: modified))
            for sub in subdirs.sorted() { visit(sub, depth: depth + 1) }
        }
        for root in roots where fm.fileExists(atPath: root) { visit((root as NSString).standardizingPath, depth: 0) }
        return FolderIndex(folders: result)
    }

    /// 파일 이름 + 당시 문맥(창 제목, URL, 업무 제목·주제)과 폴더(경로 + 들어 있는 파일 이름)의 겹침으로 후보를 고른다.
    public func rank(fileName: String, context: [String], limit: Int) -> [Folder] {
        let fileTokens = Set(Self.tokens(fileName))
        let contextTokens = Set(context.flatMap(Self.tokens))
        let scored: [(Folder, Double)] = folders.map { folder in
            let pathTokens = Set(Self.tokens(folder.relativePath))
            let contentTokens = Set(folder.sampleFiles.flatMap(Self.tokens))
            var score = 0.0
            score += 3.0 * Double(pathTokens.intersection(contextTokens).count)      // 보던 화면의 과목·프로젝트 이름이 경로에
            score += 2.0 * Double(pathTokens.intersection(fileTokens).count)         // 파일 이름이 경로에
            score += 1.0 * Double(contentTokens.intersection(fileTokens).count)      // 비슷한 이름의 파일이 이미 들어 있음
            score += 0.5 * Double(contentTokens.intersection(contextTokens).count)
            // 확장자가 같은 파일이 있으면 약간 가산
            let ext = (fileName as NSString).pathExtension.lowercased()
            if !ext.isEmpty, folder.sampleFiles.contains(where: { ($0 as NSString).pathExtension.lowercased() == ext }) { score += 0.5 }
            return (folder, score)
        }
        return scored.filter { $0.1 > 0 }.sorted { ($0.1, $0.0.depth) > ($1.1, $1.0.depth) }.prefix(limit).map(\.0)
    }

    /// 소문자 + 한글·영문·숫자 덩어리로 자른다. "AI 기초수학" 과 "AI기초수학" 은 공백을 무시해 같은 토큰으로 본다.
    public static func tokens(_ text: String) -> [String] {
        let lowered = text.lowercased()
        var tokens: [String] = []
        var current = ""
        var currentIsHangul: Bool? = nil
        func flush() { if current.count >= 2 || (current.count == 1 && current.first!.isNumber == false && currentIsHangul == true) { tokens.append(current) }; current = ""; currentIsHangul = nil }
        for char in lowered {
            let isHangul = ("\u{AC00}"..."\u{D7A3}").contains(char)
            if char.isLetter || char.isNumber {
                // 한글과 영문/숫자가 붙어 있으면("ai기초수학") 하나로 둔다: 사용자가 공백 없이 붙여 쓰는 경우가 많다
                current.append(char); if currentIsHangul == nil { currentIsHangul = isHangul }
            } else {
                flush()
            }
        }
        flush()
        // 공백으로 나뉜 "ai" + "기초수학" 도 붙인 형태를 추가해 매칭 폭을 넓힌다
        var joined: [String] = []
        for (i, token) in tokens.enumerated() where i + 1 < tokens.count {
            let next = tokens[i + 1]
            let a = token.first.map { ("\u{AC00}"..."\u{D7A3}").contains($0) } ?? false
            let b = next.first.map { ("\u{AC00}"..."\u{D7A3}").contains($0) } ?? false
            if a != b { joined.append(token + next) }
        }
        return Array(NSOrderedSet(array: tokens + joined)) as? [String] ?? tokens
    }

    public static func similar(_ a: String, _ b: String) -> Bool {
        let normalize: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        return normalize(a) == normalize(b)
    }
}
