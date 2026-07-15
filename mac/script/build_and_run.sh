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

BUILD_ARGUMENTS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination 'platform=macOS'
  -derivedDataPath "$DERIVED_DATA_PATH"
  SWIFT_ENABLE_EXPLICIT_MODULES=NO
)

run_build() {
  xcodebuild "${BUILD_ARGUMENTS[@]}" "$@" build
}

# Xcode 27 betas can omit transitive C module maps while compiling EventSource.
# Once package preparation has generated those maps, pass them explicitly. This
# is harmless on fixed Xcode releases and keeps clean command-line builds usable.
prepare_xcode_27_module_workaround() {
  local packages="$ROOT_DIR/$DERIVED_DATA_PATH/SourcePackages/checkouts"
  local generated="$ROOT_DIR/$DERIVED_DATA_PATH/Build/Intermediates.noindex/GeneratedModuleMaps"
  local numerics="$packages/swift-numerics/Sources/_NumericsShims/include"
  local csystem="$packages/swift-system/Sources/CSystem/include"
  local map

  [[ -f "$numerics/module.modulemap" && -f "$csystem/module.modulemap" ]] || return 1
  for map in CAsyncHTTPClient CNIOExtrasZlib CNIOLLHTTP CNIOPosix; do
    [[ -f "$generated/$map.modulemap" ]] || return 1
  done

  ln -sfn "$numerics" /tmp/redapp_numerics_shims
  ln -sfn "$csystem" /tmp/redapp_csystem
  mkdir -p /tmp/redapp_generated_modulemaps
  for map in CAsyncHTTPClient CNIOExtrasZlib CNIOLLHTTP CNIOPosix; do
    ln -sfn "$generated/$map.modulemap" "/tmp/redapp_generated_modulemaps/$map.modulemap"
  done

  MODULE_WORKAROUND_FLAGS='$(inherited)'
  MODULE_WORKAROUND_FLAGS+=' -Xcc -fmodule-map-file=/tmp/redapp_numerics_shims/module.modulemap -Xcc -I/tmp/redapp_numerics_shims'
  MODULE_WORKAROUND_FLAGS+=' -Xcc -fmodule-map-file=/tmp/redapp_csystem/module.modulemap -Xcc -I/tmp/redapp_csystem'
  for map in CAsyncHTTPClient CNIOExtrasZlib CNIOLLHTTP CNIOPosix; do
    MODULE_WORKAROUND_FLAGS+=" -Xcc -fmodule-map-file=/tmp/redapp_generated_modulemaps/$map.modulemap"
  done
}

if prepare_xcode_27_module_workaround; then
  run_build "OTHER_SWIFT_FLAGS=$MODULE_WORKAROUND_FLAGS"
elif ! run_build; then
  echo "Retrying with the Xcode 27 transitive module-map workaround..." >&2
  prepare_xcode_27_module_workaround
  run_build "OTHER_SWIFT_FLAGS=$MODULE_WORKAROUND_FLAGS"
fi

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
