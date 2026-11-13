import Foundation

// drive.file only reaches files the user picks in Google Picker, so the Drive API itself limits the chat tools to them.
public enum DrivePicker {
    public static let pagePath = "/drive-picker"
    public static let donePath = "/drive-picked"

    /// Args: token is a Drive access token, apiKey the Picker browser key, clientID the Google OAuth client ID, state the per-run nonce.
    /// Returns: an HTML page that opens Google Picker and reports the pick count to donePath.
    /// Raises: none.
    public static func page(token: String, apiKey: String, clientID: String, state: String) -> String {
        // Picker needs the Cloud project number as app ID; Google client IDs start with it.
        let appID = String(clientID.prefix { $0 != "-" })
        let done = "\(donePath)?state=\(state)&count="
        return """
        <!doctype html><meta charset="utf-8"><title>SILLOG · Google Drive</title>
        <body style="font-family:-apple-system,sans-serif;color:#444;padding:40px">\(tr("Google Drive에서 SILLOG이 읽을 파일을 골라 주세요."))
        <script src="https://apis.google.com/js/api.js"></script>
        <script>
        gapi.load('picker', () => {
          const view = new google.picker.DocsView().setIncludeFolders(true).setMimeTypes(\(js(readableTypes.joined(separator: ","))));
          new google.picker.PickerBuilder().addView(view)
            .enableFeature(google.picker.Feature.MULTISELECT_ENABLED)
            .setOAuthToken(\(js(token))).setDeveloperKey(\(js(apiKey))).setAppId(\(js(appID))).setOrigin(location.origin)
            .setCallback(d => {
              if (d.action === google.picker.Action.PICKED) location.href = \(js(done)) + d.docs.length;
              else if (d.action === google.picker.Action.CANCEL) location.href = \(js(done)) + 0;
            }).build().setVisible(true);
        });
        </script>
        """
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
