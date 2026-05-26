#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Build the PhoneSceneCapture app for a local iPhone.

Requirements:
  - Full Xcode selected with xcode-select, not only Command Line Tools.
  - An Apple Development team enabled in Xcode.
  - A unique bundle id for your Apple account.

Examples:
  scripts/build_iphone_app.sh --team ABCDE12345 --bundle-id com.yourname.PhoneSceneCapture
  scripts/build_iphone_app.sh --team ABCDE12345 --bundle-id com.yourname.PhoneSceneCapture --export-ipa

Options:
  --team TEAM_ID              Apple Development Team ID. Can also use DEVELOPMENT_TEAM.
  --bundle-id BUNDLE_ID       App bundle id. Defaults to PRODUCT_BUNDLE_IDENTIFIER or the project default.
  --configuration NAME        Debug or Release. Default: Release.
  --output-dir DIR            Output directory. Default: ios/PhoneSceneCapture/build/iphone
  --export-ipa                Archive and export a development .ipa instead of only building the .app.
  -h, --help                  Show this help.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IOS_DIR="$ROOT_DIR/ios/PhoneSceneCapture"
PROJECT_PATH="$IOS_DIR/PhoneSceneCapture.xcodeproj"
SCHEME="PhoneSceneCapture"
CONFIGURATION="Release"
TEAM_ID="${DEVELOPMENT_TEAM:-}"
BUNDLE_ID="${PRODUCT_BUNDLE_IDENTIFIER:-com.vrshydra.PhoneSceneCapture}"
OUTPUT_DIR="$IOS_DIR/build/iphone"
EXPORT_IPA=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team)
      TEAM_ID="${2:?Missing value for --team}"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:?Missing value for --bundle-id}"
      shift 2
      ;;
    --configuration)
      CONFIGURATION="${2:?Missing value for --configuration}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:?Missing value for --output-dir}"
      shift 2
      ;;
    --export-ipa)
      EXPORT_IPA=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! xcrun --find xcodebuild >/dev/null 2>&1; then
  cat >&2 <<'ERROR'
Cannot find xcodebuild.

Install full Xcode from the App Store or Apple Developer, then run:
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
ERROR
  exit 1
fi

if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  echo "Cannot find the iphoneos SDK. Make sure full Xcode is installed and selected." >&2
  exit 1
fi

if [[ -z "$TEAM_ID" ]]; then
  cat >&2 <<'WARNING'
No Apple Development Team ID was provided.
The build may fail during code signing. Pass --team TEAM_ID or set DEVELOPMENT_TEAM.
WARNING
fi

mkdir -p "$OUTPUT_DIR"

BUILD_SETTINGS=(
  "CODE_SIGN_STYLE=Automatic"
  "PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID"
)

if [[ -n "$TEAM_ID" ]]; then
  BUILD_SETTINGS+=("DEVELOPMENT_TEAM=$TEAM_ID")
fi

if [[ "$EXPORT_IPA" -eq 1 ]]; then
  ARCHIVE_PATH="$OUTPUT_DIR/PhoneSceneCapture.xcarchive"
  EXPORT_OPTIONS="$OUTPUT_DIR/exportOptions.plist"

  /usr/libexec/PlistBuddy -c "Clear dict" "$EXPORT_OPTIONS" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :method string development" "$EXPORT_OPTIONS"
  /usr/libexec/PlistBuddy -c "Add :signingStyle string automatic" "$EXPORT_OPTIONS"
  /usr/libexec/PlistBuddy -c "Add :destination string export" "$EXPORT_OPTIONS"
  /usr/libexec/PlistBuddy -c "Add :stripSwiftSymbols bool true" "$EXPORT_OPTIONS"
  if [[ -n "$TEAM_ID" ]]; then
    /usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$EXPORT_OPTIONS"
  fi

  xcodebuild archive \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    "${BUILD_SETTINGS[@]}"

  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$OUTPUT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates

  echo "Exported development IPA to: $OUTPUT_DIR"
else
  DERIVED_DATA="$OUTPUT_DIR/DerivedData"

  xcodebuild build \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    "${BUILD_SETTINGS[@]}"

  APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos/PhoneSceneCapture.app"
  echo "Built iPhone app: $APP_PATH"
fi
