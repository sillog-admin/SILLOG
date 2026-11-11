#!/bin/bash
# release 빌드 → 코드 서명 → ~/Applications/SILLOG.app 설치.
# 서명 인증서를 고정해 두면 다시 빌드해도 macOS 권한(손쉬운 사용·화면 기록)이 유지된다.
#   SIGN_IDENTITY="Apple Development: ..." scripts/make-app.sh   # 인증서 지정
#   SIGN_IDENTITY=- scripts/make-app.sh                          # ad-hoc (빌드할 때마다 권한을 다시 줘야 함)
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
swift build --package-path "$STAGE_DIR" -c release --product SillogApp --scratch-path "$BUILD_DIR" --cache-path "$BUILD_DIR/cache" --config-path "$BUILD_DIR/config" --security-path "$BUILD_DIR/security" --disable-sandbox -j 2
BIN_DIR="$(swift build --package-path "$STAGE_DIR" -c release --show-bin-path --scratch-path "$BUILD_DIR" --cache-path "$BUILD_DIR/cache" --config-path "$BUILD_DIR/config" --security-path "$BUILD_DIR/security" --disable-sandbox)"
APP="$BUILD_DIR/Sillog.app"
APP_LINK="$ROOT/build/SILLOG.app"
INSTALLED_APP="$HOME/Applications/SILLOG.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SillogApp" "$APP/Contents/MacOS/Sillog"
cp -R "$ROOT/Sources/SillogApp/Resources/graph" "$APP/Contents/Resources/graph"
cp -R "$ROOT/Sources/SillogApp/Resources/calendar" "$APP/Contents/Resources/calendar"   # 캘린더 화면 (FullCalendar 6, MIT)
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
  <key>NSMicrophoneUsageDescription</key><string>메뉴 막대에서 녹음할 때 마이크 소리를 녹음합니다.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>녹음한 말을 이 Mac 안에서 글로 받아씁니다.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>받아쓴 녹음을 문서 폴더의 'SILLOG 녹음'에 저장합니다.</string>
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

# OAuth client settings: env (SILLOG_* or legacy WORKGRAPH_*), then Config/OAuthClients.plist.
OAUTH_CONFIG="$ROOT/Config/OAuthClients.plist"
for name in GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GITHUB_CLIENT_ID NOTION_CLIENT_ID SLACK_CLIENT_ID; do
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

# 서명: 지정값 → "Apple Development" → ad-hoc 순으로 고른다.
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  AVAILABLE="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  for candidate in "Apple Development"; do
    if echo "$AVAILABLE" | grep -q "\"$candidate"; then
      IDENTITY="$(echo "$AVAILABLE" | grep "\"$candidate" | head -1 | sed -E 's/.*"(.*)".*/\1/')"
      break
    fi
  done
fi
IDENTITY="${IDENTITY:--}"

sign() {   # 키체인 확인 창에서 멈추는 경우를 대비해 25초 제한
  codesign --force --sign "$1" "$APP" &
  local pid=$!
  ( sleep 25; kill "$pid" 2>/dev/null ) &
  local watchdog=$!
  local status=0
  wait "$pid" || status=$?
  kill "$watchdog" 2>/dev/null || true
  return "$status"
}

if [ "$IDENTITY" != "-" ] && sign "$IDENTITY"; then
  echo "서명: $IDENTITY"
else
  [ "$IDENTITY" != "-" ] && echo "'$IDENTITY' 서명 실패 → ad-hoc 으로 서명합니다 (다시 빌드하면 권한을 다시 줘야 합니다)"
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
