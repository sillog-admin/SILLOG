import Foundation

/// Reads `SILLOG_<name>`, falling back to the pre-rename `WORKGRAPH_<name>`.
public enum SillogEnv {
    public static func value(_ name: String, in environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        [environment["SILLOG_\(name)"], environment["WORKGRAPH_\(name)"]].compactMap { $0 }.first { !$0.isEmpty }
    }
}
