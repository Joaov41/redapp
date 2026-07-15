#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="redapp"
BUNDLE_ID="com.jv.redapp"
PROJECT="redapp2.xcodeproj"
SCHEME="redapp-macOS"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="build/DerivedData-MacRun"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO \
  build

APP_BUNDLE="$ROOT_DIR/$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
if [[ ! -d "$APP_BUNDLE" ]]; then
  APP_BUNDLE="$(find "$ROOT_DIR/$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION" -maxdepth 1 -name '*.app' -print -quit)"
fi

if [[ -z "${APP_BUNDLE:-}" || ! -d "$APP_BUNDLE" ]]; then
  echo "Built app bundle not found under $DERIVED_DATA_PATH/Build/Products/$CONFIGURATION" >&2
  exit 1
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
