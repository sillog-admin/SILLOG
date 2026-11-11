// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Sillog",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SillogCore", targets: ["SillogCore"]),
        .executable(name: "SillogApp", targets: ["SillogApp"]),
        .executable(name: "sillogctl", targets: ["sillogctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // LangGraph for Swift: 문서 플러그인을 브랜치로 물고 있어 버전이 아니라 커밋으로 고정 (마지막 커밋 2025-08-01)
        .package(url: "https://github.com/bsorrentino/LangGraph-Swift.git", revision: "d91c62aaa25e818f2667482c6edbe635a375ec45"),
        // 채팅 답의 LaTeX 수식을 앱 안에서 그린다 (네이티브, MIT). 수식 글꼴에 없는 글자(한글·①)용 대체 글꼴이 1.7.3 뒤에 들어와 커밋으로 고정 (2026-06-29)
        .package(url: "https://github.com/mgriebling/SwiftMath.git", revision: "1d2c90827e9c3908269d810d055fb03b7da5fd53"),
        // 녹음 받아쓰기: Whisper 를 Core ML 로 기기 안에서 (MIT). 애플 기기 안 인식은 작은 소리·긴 녹음을 놓친다 (10/13 측정)
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        .target(
            name: "SillogCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift"), .product(name: "LangGraph", package: "LangGraph-Swift")],
            resources: [.copy("Chat/Skills"), .copy("Chat/Prompts"), .copy("Localization/en.json")]
        ),
        .target(
            name: "SillogCollectors",
            dependencies: ["SillogCore"]
        ),
        .executableTarget(
            name: "SillogApp",
            dependencies: ["SillogCore", "SillogCollectors", .product(name: "SwiftMath", package: "SwiftMath"),
                           .product(name: "WhisperKit", package: "WhisperKit")],
            exclude: ["Resources/AppIcon.icns"],            // .app 번들에는 scripts/make-app.sh 가 직접 넣는다
            resources: [.copy("Resources/graph"), .copy("Resources/calendar"), .copy("Resources/ConnectorIcons"), .copy("Resources/Brand")]
        ),
        .executableTarget(
            name: "sillogctl",
            dependencies: ["SillogCore", "SillogCollectors", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "SillogCoreTests",
            dependencies: ["SillogCore"]
        ),
        // 앱 화면 동작 테스트: 미리보기 상태(AppState(preview:))로 화면 밖 창에 그려 본다. 실제 DB·실행 잠금은 쓰지 않는다
        .testTarget(
            name: "SillogAppTests",
            dependencies: ["SillogApp", "SillogCore"]
        ),
    ]
)
