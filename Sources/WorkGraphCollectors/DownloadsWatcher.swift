import CoreServices
import Foundation

/// 폴더(기본 ~/Downloads)에 새 파일이 생기는 것을 본다. 다운로드 출처 URL 은 파일의 확장 속성에서 읽는다.
public final class DownloadsWatcher: @unchecked Sendable {
    private let paths: [String]
    private let onFile: @Sendable (_ path: String, _ originURL: String?) -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "workgraph.downloads", qos: .utility)
    private var recent: [String: Double] = [:]
    static let temporarySuffixes = [".crdownload", ".download", ".part", ".tmp", ".partial"]

    public init(paths: [String], onFile: @escaping @Sendable (_ path: String, _ originURL: String?) -> Void) {
        self.paths = paths
        self.onFile = onFile
    }

    public func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DownloadsWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let list = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            for index in 0..<min(count, list.count) { watcher.handle(path: list[index], flags: flags[index]) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(path: String, flags: FSEventStreamEventFlags) {
        let isFile = flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0
        let appeared = flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0
        guard isFile, appeared else { return }
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix("."), !Self.temporarySuffixes.contains(where: { name.lowercased().hasSuffix($0) }),
              FileManager.default.fileExists(atPath: path) else { return }     // 이름 바꾸기의 "옛 이름" 쪽은 여기서 걸러진다
        let now = Date().timeIntervalSince1970
        if let last = recent[path], now - last < 5 { return }
        recent[path] = now
        if recent.count > 200 { recent = recent.filter { now - $0.value < 60 } }
        onFile(path, Self.whereFrom(path: path))
    }

    /// com.apple.metadata:kMDItemWhereFroms — 브라우저가 내려받은 파일에 남기는 출처 URL 목록.
    public static func whereFrom(path: String) -> String? {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        guard read > 0, let list = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String] else { return nil }
        return list.first { $0.hasPrefix("http") }
    }
}
