#!/bin/bash
# release 빌드 → 코드 서명 → ~/Applications/SILLOG.app 설치.
# 서명 인증서를 고정해 두면 다시 빌드해도 macOS 권한(손쉬운 사용·화면 기록)이 유지된다.
#   SIGN_IDENTITY="Developer ID Application" scripts/make-app.sh   # 인증서 지정. 지정한 인증서로 서명하지 못하면 멈춘다
#   SIGN_IDENTITY=- scripts/make-app.sh                  # ad-hoc (빌드할 때마다 권한을 다시 줘야 함)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ -f .env ]; then set -a; . ./.env; set +a; fi

# Documents의 동기화 파일 때문에 SwiftPM 의존성 체크아웃이 멈추지 않도록 임시 빌드 경로를 쓴다.
BUILD_DIR="${SILLOG_BUILD_DIR:-${WORKGRAPH_BUILD_DIR:-${TMPDIR:-/tmp}/Sillog-swift-build}}"
mkdir -p "$BUILD_DIR/cache" "$BUILD_DIR/config" "$BUILD_DIR/security" "$BUILD_DIR/clang-cache"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$BUILD_DIR/clang-cache}"
# 동기화 중인 Documents 원본의 메타데이터가 컴파일 도중 바뀌지 않도록 소스를 임시 경로에 고정한다.
STAGE_DIR="$BUILD_DIR/source"
mkdir -p "$STAGE_DIR/Sources" "$STAGE_DIR/Tests"
rsync -a --delete "$ROOT/Sources/" "$STAGE_DIR/Sources/"
rsync -a --delete "$ROOT/Tests/" "$STAGE_DIR/Tests/"
cp "$ROOT/Package.swift" "$ROOT/Package.resolved" "$STAGE_DIR/"
# Swift Build's Bundle.module looks in Contents/Resources, where the bundles are copied below. The native build system
# (Swift 6.2's default) looks only at the app root and this build folder, so the released app crashed on a user's Mac.
for product in SillogApp sillogctl; do   # sillogctl is the MCP server other AI apps launch
swift build --package-path "$STAGE_DIR" -c release --build-system swiftbuild --product "$product" --scratch-path "$BUILD_DIR" --cache-path "$BUILD_DIR/cache" --config-path "$BUILD_DIR/config" --security-path "$BUILD_DIR/security" --disable-sandbox -j 2
done
BIN_DIR="$(swift build --package-path "$STAGE_DIR" -c release --build-system swiftbuild --show-bin-path --scratch-path "$BUILD_DIR" --cache-path "$BUILD_DIR/cache" --config-path "$BUILD_DIR/config" --security-path "$BUILD_DIR/security" --disable-sandbox)"
APP="$BUILD_DIR/Sillog.app"
APP_LINK="$ROOT/build/SILLOG.app"
INSTALLED_APP="$HOME/Applications/SILLOG.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SillogApp" "$APP/Contents/MacOS/Sillog"
cp "$BIN_DIR/sillogctl" "$APP/Contents/MacOS/sillogctl"
# Swift Build stamps the deployment target (14.0) as the SDK version, so macOS 26 draws the app in the old compatibility
# look (short title bar, no glass). Restamp the SDK the app was really built with.
SDK_VER="$(xcrun --sdk macosx --show-sdk-version)"
for bin in "$APP/Contents/MacOS/Sillog" "$APP/Contents/MacOS/sillogctl"; do
  vtool -set-build-version macos 14.0 "$SDK_VER" -replace -output "$bin.tmp" "$bin" && mv "$bin.tmp" "$bin"
done
cp -R "$ROOT/Sources/SillogApp/Resources/graph" "$APP/Contents/Resources/graph"
cp -R "$ROOT/Sources/SillogApp/Resources/calendar" "$APP/Contents/Resources/calendar"   # 캘린더 화면 (FullCalendar 6, MIT)
cp -R "$ROOT/Sources/SillogApp/Resources/mermaid" "$APP/Contents/Resources/mermaid"     # 채팅 다이어그램 (mermaid 11.4.1, MIT)
cp -R "$ROOT/Sources/SillogApp/Resources/ConnectorIcons" "$APP/Contents/Resources/ConnectorIcons"
cp -R "$ROOT/Sources/SillogApp/Resources/Brand" "$APP/Contents/Resources/Brand"
cp -R "$BIN_DIR/Sillog_SillogCore.bundle" "$APP/Contents/Resources/"
cp -R "$BIN_DIR/SwiftMath_SwiftMath.bundle" "$APP/Contents/Resources/"    # 채팅 수식 글꼴 (없으면 수식을 그릴 때 앱이 멈춘다)
chmod -R u+w "$APP/Contents/Resources/SwiftMath_SwiftMath.bundle"                    # 패키지 체크아웃에서 읽기 전용으로 오므로 서명 전 xattr 정리가 되게
[ -f "$ROOT/Sources/SillogApp/Resources/AppIcon.icns" ] || swift "$ROOT/scripts/make-icon.swift" "$ROOT/Sources/SillogApp/Resources/AppIcon.icns"
cp "$ROOT/Sources/SillogApp/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.sillog.app</string>
  <key>CFBundleName</key><string>SILLOG</string>
  <key>CFBundleDisplayName</key><string>SILLOG</string>
  <key>CFBundleExecutable</key><string>Sillog</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>com.sillog.app.oauth</string>
    <key>CFBundleURLSchemes</key><array><string>sillog</string></array>
    <key>CFBundleTypeRole</key><string>Viewer</string>
  </dict></array>
  <key>NSDownloadsFolderUsageDescription</key><string>새로 내려받은 파일을 하던 업무와 연결해 기록합니다.</string>
  <key>NSMicrophoneUsageDescription</key><string>메뉴 막대에서 녹음하거나 채팅에 말로 입력할 때 마이크 소리를 듣습니다.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>녹음한 말과 채팅에 말로 입력한 내용을 이 Mac 안에서 글로 받아씁니다.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>받아쓴 녹음을 문서 폴더의 'SILLOG 녹음'에 저장합니다.</string>
  <key>NSDesktopFolderUsageDescription</key><string>내려받은 파일을 넣을 폴더를 제안하려고 데스크탑의 폴더를 살펴봅니다.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>오늘 일정을 메뉴 막대에 보여 주고, 기록에서 찾은 일정을 확인한 뒤 캘린더에 등록합니다.</string>
  <key>NSCalendarsUsageDescription</key><string>오늘 일정을 메뉴 막대에 보여 주고, 기록에서 찾은 일정을 확인한 뒤 캘린더에 등록합니다.</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
    <key>NSAllowsArbitraryLoads</key><true/>
  </dict>
</dict>
</plist>
PLIST
# CI's run number, so a crash report names the release build it came from.
plutil -replace CFBundleVersion -string "${GITHUB_RUN_NUMBER:-1}" "$APP/Contents/Info.plist"
# Each CI build is a release, so its run number is also the last version part (0.1.0 -> 0.1.96). Bump 0.1 above by hand.
if [ -n "${GITHUB_RUN_NUMBER:-}" ]; then
  base="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
  plutil -replace CFBundleShortVersionString -string "${base%.*}.$GITHUB_RUN_NUMBER" "$APP/Contents/Info.plist"
fi

# OAuth client settings: env (SILLOG_* or legacy WORKGRAPH_*), then Config/OAuthClients.plist.
OAUTH_CONFIG="$ROOT/Config/OAuthClients.plist"
for name in GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GOOGLE_API_KEY GITHUB_CLIENT_ID GITHUB_APP_SLUG NOTION_CLIENT_ID SLACK_CLIENT_ID; do
  key="SILLOG_$name"
  legacy="WORKGRAPH_$name"
  oauth_value="${!key:-${!legacy:-}}"
  if [ -z "$oauth_value" ] && [ -f "$OAUTH_CONFIG" ]; then
    if ! oauth_value="$(plutil -extract "$key" raw -o - "$OAUTH_CONFIG" 2>/dev/null)"; then oauth_value=""; fi
  fi
  if [ -n "$oauth_value" ]; then
    plutil -insert "$key" -string "$oauth_value" "$APP/Contents/Info.plist"
  fi
done

# File Provider의 Finder 메타데이터가 서명을 깨므로 번들에서 제거한다.
xattr -cr "$APP"

# Identity: SIGN_IDENTITY, then Developer ID, then SILLOG Release, then Apple Development, then ad-hoc.
# SILLOG Release 는 릴리스와 같은 자체 서명 인증서라 신뢰 목록(-v)에 없으므로 -v 없이 찾는다.
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  AVAILABLE="$(security find-identity -p codesigning 2>/dev/null || true)"
  for candidate in "Developer ID Application" "SILLOG Release" "Apple Development"; do
    if echo "$AVAILABLE" | grep -q "\"$candidate"; then
      IDENTITY="$(echo "$AVAILABLE" | grep "\"$candidate" | head -1 | sed -E 's/.*"(.*)".*/\1/')"
      break
    fi
  done
fi
IDENTITY="${IDENTITY:--}"

sign() {   # identity, then codesign arguments. 25s cap in case a Keychain prompt blocks codesign
  # Hardened runtime and a timestamp are what notarization requires.
  codesign --force --options runtime --timestamp --sign "$1" "${@:2}" &
  local pid=$!
  ( sleep 25; kill "$pid" 2>/dev/null ) &
  local watchdog=$!
  local status=0
  wait "$pid" || status=$?
  kill "$watchdog" 2>/dev/null || true
  return "$status"
}

# Nested code is signed before the app that seals it.
if [ "$IDENTITY" != "-" ] && sign "$IDENTITY" "$APP/Contents/MacOS/sillogctl" && sign "$IDENTITY" --entitlements "$ROOT/scripts/SILLOG.entitlements" "$APP"; then
  echo "서명: $IDENTITY"
elif [ -n "${SIGN_IDENTITY:-}" ] && [ "$SIGN_IDENTITY" != "-" ]; then
  # A release must never fall back to ad-hoc, or every user is asked for keychain access and permissions again.
  echo "'$SIGN_IDENTITY' 로 서명하지 못했습니다" >&2
  exit 1
else
  [ "$IDENTITY" != "-" ] && echo "'$IDENTITY' 서명 실패 → ad-hoc 으로 서명합니다 (다시 빌드하면 권한을 다시 줘야 합니다)"
  codesign --force --sign - "$APP/Contents/MacOS/sillogctl"
  codesign --force --sign - "$APP"
  echo "서명: ad-hoc"
fi

mkdir -p "$(dirname "$INSTALLED_APP")" "$ROOT/build"
if [ "$APP" != "$INSTALLED_APP" ]; then
  rm -rf "$INSTALLED_APP"
  mv "$APP" "$INSTALLED_APP"
fi
rm -rf "$APP_LINK"
ln -s "$INSTALLED_APP" "$APP_LINK"
echo "설치: $INSTALLED_APP"
echo "완성: $APP_LINK"
echo "실행: open \"$APP_LINK\""
