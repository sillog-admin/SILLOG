import Foundation
import Security

/// Swaps the running SILLOG.app for the one inside a release dmg.
public enum UpdateInstaller {
    public struct Failure: LocalizedError, CustomStringConvertible {
        public let description: String
        public var errorDescription: String? { tr("업데이트를 설치하지 못했어요.") }
    }

    /// Args: dmg is the release SILLOG.dmg link; target is the app bundle to replace; session downloads the dmg.
    /// Returns: nothing; target holds the new app once it returns.
    /// Raises: Failure when the download, mount, copy, signature check or swap fails; target is left as it was.
    public static func install(dmg: URL, replacing target: URL = Bundle.main.bundleURL, session: URLSession = .shared) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("sillog-update-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        do {
            let image = work.appendingPathComponent("SILLOG.dmg"), mount = work.appendingPathComponent("mount")
            try fm.createDirectory(at: mount, withIntermediateDirectories: true)
            // URLSession adds no quarantine attribute, so Gatekeeper won't block the copied app.
            let (file, response) = try await session.download(from: dmg)
            try fm.moveItem(at: file, to: image)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw Failure(description: "download HTTP \(status)") }

            // Same volume as target so replaceItemAt is a rename.
            let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
            defer { try? fm.removeItem(at: staging) }
            let app = staging.appendingPathComponent(target.lastPathComponent)
            try run("/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, image.path)
            do {
                defer { try? run("/usr/bin/hdiutil", "detach", "-force", mount.path) }
                let apps = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
                guard apps.count == 1 else { throw Failure(description: "dmg holds \(apps.count) apps") }
                try run("/usr/bin/ditto", apps[0].path, app.path)
            }
            try verify(app)
            _ = try fm.replaceItemAt(target, withItemAt: app)
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure(description: "\(error)")
        }
    }

    /// Args: app is the copied bundle.
    /// Returns: nothing when app satisfies the running app's designated requirement and has its bundle id.
    /// Raises: Failure otherwise; an ad-hoc or unsigned running app always fails here.
    static func verify(_ app: URL) throws {
        var me: SecCode?, mine: SecStaticCode?, requirement: SecRequirement?, new: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &new) == errSecSuccess, let new else {
            throw Failure(description: "signature unreadable")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(new, flags, requirement)
        guard status == errSecSuccess else { throw Failure(description: "signature check \(status)") }
        let id = Bundle(url: app)?.bundleIdentifier
        guard id != nil, id == Bundle.main.bundleIdentifier else { throw Failure(description: "bundle id \(id ?? "none")") }
    }

    /// Args: tool is an absolute executable path; arguments are passed as-is.
    /// Returns: nothing once the tool exits 0.
    /// Raises: Failure with the exit code and the tool's stderr, or the launch error from Process.run.
    private static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)   // read before waiting so a full pipe can't block the tool
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(description: "\(tool) \(arguments[0]) exit \(process.terminationStatus): \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
