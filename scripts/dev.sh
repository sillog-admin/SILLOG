#!/bin/bash
# 개발용 실행: 데모 기록으로 디버그 빌드를 띄우고, Sources 를 저장하면 다시 빌드해서 다시 띄운다 (Ctrl+C 로 끝).
# 실제 앱(실제 기록)은 그대로 둔 채 옆에서 뜬다: DB 가 달라 실행 잠금이 겹치지 않고, SILLOG_DEV 라 온보딩·기록·정리를 하지 않는다.
#   scripts/dev.sh             # 그래프 탭으로 시작
#   scripts/dev.sh chat        # 시작 탭 (SILLOG_TAB 값: graph, chat, records, calendar, settings)
#   scripts/dev.sh --fresh     # 데모 기록을 새로 만든다
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DEV_DIR="${SILLOG_DEV_DIR:-${TMPDIR:-/tmp}/sillog-dev}"
DB="$DEV_DIR/sillog.sqlite"
if [ "${1:-}" = "--fresh" ]; then rm -rf "$DEV_DIR"; shift; fi
TAB="${1:-graph}"

if [ ! -f "$DB" ]; then                                  # 데모 기록: 최근 일주일 중 닷새 (기간 막대가 보이게)
  mkdir -p "$DEV_DIR"
  for ago in 6 4 2 1 0; do swift run sillogctl --db "$DB" seed-demo --day "$(date -v-"${ago}"d +%F)"; done
  swift run sillogctl --db "$DB" batch --all --demo-llm
fi

swift build --product SillogApp
BIN="$(swift build --show-bin-path)/SillogApp"
# 번들 없이 띄우면 SwiftUI 가 메인 창을 열지 못한다: 디버그 실행 파일을 작은 .app 에 넣는다.
# 번들 id 가 달라(com.sillog.app.dev) 실제 앱의 설정(UserDefaults)과 섞이지 않는다. 리소스는 빌드 폴더에서 찾는다
BUNDLE="$DEV_DIR/SILLOG Dev.app"
mkdir -p "$BUNDLE/Contents/MacOS"
# Resources 는 원본 폴더(글꼴·그래프·캘린더 화면)를 통째로 가리킨다: 복사하지 않으니 저장한 내용이 그대로 쓰이고,
# 웹 화면이 링크를 실제 경로로 풀어도 읽기 허용 범위 안에 있다. 모듈 리소스(.bundle)는 SwiftPM 이 빌드 폴더에서 찾는다
[ -L "$BUNDLE/Contents/Resources" ] || rm -rf "$BUNDLE/Contents/Resources"
ln -sfn "$ROOT/Sources/SillogApp/Resources" "$BUNDLE/Contents/Resources"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.sillog.app.dev</string>
  <key>CFBundleName</key><string>SILLOG Dev</string>
  <key>CFBundleExecutable</key><string>Sillog</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
APP=""
start() {
  rm -f "$BUNDLE/Contents/MacOS/Sillog"   # a copy over the old file keeps its inode, and macOS kills the launch for the stale cached signature
  cp "$BIN" "$BUNDLE/Contents/MacOS/Sillog"
  SILLOG_DEV=1 SILLOG_DB="$DB" SILLOG_SHOW_WINDOW=1 SILLOG_TAB="$TAB" "$BUNDLE/Contents/MacOS/Sillog" & APP=$!
  echo "▶ 개발용 SILLOG (pid $APP, 데모 DB $DB)"
}
stop() { if [ -n "$APP" ]; then kill "$APP" 2>/dev/null || true; wait "$APP" 2>/dev/null || true; APP=""; fi; }
trap 'stop; exit 0' INT TERM

STAMP="$DEV_DIR/.built"
touch "$STAMP"
start
while sleep 1; do
  [ -z "$(find Sources -newer "$STAMP" -type f -print -quit)" ] && continue
  touch "$STAMP"
  echo "↻ 바뀐 파일이 있어 다시 빌드해요"
  if swift build --product SillogApp > "$DEV_DIR/build.log" 2>&1; then stop; start
  else grep -E "error:" "$DEV_DIR/build.log" | head -20; echo "✗ 빌드 실패: 고치고 저장하면 다시 해요 (앱은 그대로 둬요)"; fi
done
