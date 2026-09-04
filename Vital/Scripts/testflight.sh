#!/bin/zsh
# Archive Vital (Release, no bundled seed) and upload to TestFlight through the Apple ID signed into Xcode.
#   Vital/Scripts/testflight.sh            # upload
#   Vital/Scripts/testflight.sh --export   # build the .ipa into Vital/Scripts/out/ without uploading
set -euo pipefail
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
BUILD=$(date +%Y%m%d%H%M)                       # unique, monotonically increasing build number
OUT="Vital/Scripts/out"; mkdir -p "$OUT"
ARCHIVE="$OUT/Vital.xcarchive"
OPTS="Vital/Scripts/ExportOptions.plist"
if [[ "${1:-}" == "--export" ]]; then
  OPTS="$OUT/ExportOptions.export.plist"
  /usr/libexec/PlistBuddy -c "Set :destination export" -x "Vital/Scripts/ExportOptions.plist" > /dev/null 2>&1 || true
  sed 's#<string>upload</string>#<string>export</string>#' Vital/Scripts/ExportOptions.plist > "$OPTS"
fi
xcodegen generate > /dev/null
echo "Archiving Vital build $BUILD (Release)…"
xcodebuild -project Strand.xcodeproj -scheme Vital -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates VITAL_BUILD="$BUILD" -quiet archive
echo "Exporting / uploading…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTS" \
  -exportPath "$OUT/export" -allowProvisioningUpdates
echo "Done. Build $BUILD."
