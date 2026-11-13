import Foundation

// drive.file only reaches files the user picks in Google Picker.
// Picker can't run in an embedded web view, so it opens in the browser and reports file IDs to a loopback URL.
public enum DrivePicker {
    public static let pagePath = "/drive-picker"
    public static let donePath = "/drive-picked"

    /// Args: token is a Drive access token, apiKey the Picker browser key, clientID the Google OAuth client ID, state the per-run nonce.
    /// Returns: an HTML page that opens Google Picker and sends the picked file IDs, comma-separated, to donePath.
    /// Raises: none.
    public static func page(token: String, apiKey: String, clientID: String, state: String) -> String {
        // Picker needs the Cloud project number as app ID; Google client IDs start with it.
        let appID = String(clientID.prefix { $0 != "-" })
        let done = "\(donePath)?state=\(state)&ids="
        return """
        <!doctype html><meta charset="utf-8"><title>SILLOG · Google Drive</title>
        <body style="font-family:-apple-system,sans-serif;color:#444;padding:40px">\(tr("Google Drive에서 SILLOG이 읽을 파일을 골라 주세요."))
        <script src="https://apis.google.com/js/api.js"></script>
        <script>
        gapi.load('picker', () => {
          const view = new google.picker.DocsView().setIncludeFolders(true).setMimeTypes(\(js(readableTypes.joined(separator: ","))));
          new google.picker.PickerBuilder().addView(view)
            .enableFeature(google.picker.Feature.MULTISELECT_ENABLED).setMaxItems(50)
            .setOAuthToken(\(js(token))).setDeveloperKey(\(js(apiKey))).setAppId(\(js(appID))).setOrigin(location.origin)
            .setCallback(d => {
              if (d.action === google.picker.Action.PICKED) location.href = \(js(done)) + encodeURIComponent(d.docs.map(x => x.id).join(','));
              else if (d.action === google.picker.Action.CANCEL) location.href = \(js(done));
            }).build().setVisible(true);
        });
        </script>
        """
    }

    /// Args: ids are picked Drive file IDs, token a Drive access token, session the HTTP session.
    /// Returns: each file's name, type and link; malformed IDs and files whose details fail are skipped.
    /// Raises: the last HTTP error when no file's details could be read, or network errors from the Drive API.
    public static func files(ids: [String], token: String, session: URLSession = ConnectorHTTP.session) async throws -> [ChatDriveFile] {
        var files: [ChatDriveFile] = []
        var failedStatus: Int?
        for id in ids where id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil {
            var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?fields=id,name,mimeType,webViewLink")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                failedStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
                continue
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            files.append(ChatDriveFile(id: id, name: json["name"] as? String ?? id, mimeType: json["mimeType"] as? String ?? "",
                                       url: json["webViewLink"] as? String ?? "https://drive.google.com/open?id=\(id)"))
        }
        if files.isEmpty, let failedStatus { throw ChatToolError.unavailable(tr("Drive 파일 정보를 읽지 못했습니다 (HTTP \(failedStatus)).")) }
        return files
    }

    /// Types `ChatTools.driveRead` can turn into text.
    static let readableTypes = ["application/vnd.google-apps.document", "application/vnd.google-apps.spreadsheet",
                                "application/vnd.google-apps.presentation", "application/pdf", "application/json",
                                "text/plain", "text/markdown", "text/csv", "text/html"]

    private static func js(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = (try? encoder.encode(value)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
    }
}
