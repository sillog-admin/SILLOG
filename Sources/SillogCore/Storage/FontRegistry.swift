import CoreText
import Foundation

/// 앱에 넣은 글꼴 파일을 이 프로세스에서만 쓰도록 등록한다 (시스템에 설치하지 않는다)
public enum FontRegistry {
    /// Args: directory — .otf/.ttf 파일이 든 폴더.
    /// Returns: 등록됐거나 이미 등록·설치돼 있던 글꼴의 PostScript 이름. 폴더가 없으면 빈 목록.
    /// Raises: 없음. 읽지 못한 파일은 건너뛴다.
    public static func register(directory: URL) -> [String] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["otf", "ttf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var names: [String] = []
        for file in files {
            var error: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error)
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
            let usable = registered
                || code == CTFontManagerError.alreadyRegistered.rawValue
                || code == CTFontManagerError.duplicatedName.rawValue
            if usable { names += postScriptNames(file) }
        }
        return names
    }

    static func postScriptNames(_ file: URL) -> [String] {
        let descriptors = (CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor]) ?? []
        return descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
    }
}
