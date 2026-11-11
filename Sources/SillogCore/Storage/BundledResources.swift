import Foundation

/// 앱 리소스 찾기. .app 으로 실행하면 Contents/Resources(main)만 보고, swift run 이면 SwiftPM 리소스 번들(module)을 본다.
/// SwiftPM 이 만든 Bundle.module 은 자기 번들을 못 찾으면 앱을 끝내 버리는데, scripts/make-app.sh 의 .app 에는 그 번들이 없다.
/// 그래서 .app 에서는 module 을 부르지 않는다 (없는 리소스는 nil, 화면은 기본값으로 그린다).
public enum BundledResources {
    public static func url(forResource name: String, withExtension ext: String?, subdirectory: String?,
                           main: Bundle, module: () -> Bundle) -> URL? {
        if main.bundleURL.pathExtension == "app" {
            return main.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
        }
        return module().url(forResource: name, withExtension: ext, subdirectory: subdirectory)
    }
}
