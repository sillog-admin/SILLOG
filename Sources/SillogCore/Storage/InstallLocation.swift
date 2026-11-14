import Foundation

public enum InstallLocation {
    /// Args: app is the running bundle's URL.
    /// Returns: true for an .app inside an attached dmg or in the read-only copy macOS translocates a quarantined app to.
    ///   Both vanish on eject or restart, and the login item registered from them goes too.
    /// Raises: none. A volume that can't be read counts as writable, so the app still starts.
    public static func needsMove(_ app: URL) -> Bool {
        guard app.pathExtension == "app" else { return false }
        return app.path.contains("/AppTranslocation/") || (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
    }
}
