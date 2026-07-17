#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
project_directory="${script_directory:h}"
release_configuration="${TWAINBRIDGE_RELEASE_CONFIG:-${project_directory}/Config/Release.xcconfig}"
release_root="${TWAINBRIDGE_RELEASE_ROOT:-${project_directory}/build/Release}"
archive_path="${release_root}/TwainBridge.xcarchive"
notary_profile="${TWAINBRIDGE_NOTARY_PROFILE:-}"

if [[ ! -f "${release_configuration}" ]]; then
  print -u2 "Missing release configuration: ${release_configuration}"
  exit 2
fi
if [[ -z "${notary_profile}" ]]; then
  print -u2 "Set TWAINBRIDGE_NOTARY_PROFILE to a notarytool Keychain profile."
  exit 2
fi

"${project_directory}/Scripts/preflight.sh"
mkdir -p "${release_root}"
cd "${project_directory}"
xcodegen generate

xcodebuild \
  -project TwainBridge.xcodeproj \
  -scheme TwainBridge \
  -configuration Release \
  -xcconfig "${release_configuration}" \
  -archivePath "${archive_path}" \
  -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  archive

application_path="${archive_path}/Products/Applications/TwainBridge.app"
codesign --verify --deep --strict --verbose=2 "${application_path}"
codesign -d --verbose=4 "${application_path}" 2>&1 | rg -q 'flags=.*runtime' || {
  print -u2 "The archived app is missing Hardened Runtime."
  exit 3
}
architectures="$(lipo -archs "${application_path}/Contents/MacOS/TwainBridge")"
if [[ " ${architectures} " != *" arm64 "* || " ${architectures} " != *" x86_64 "* ]]; then
  print -u2 "Archive is not universal: ${architectures}"
  exit 3
fi

info_plist="${application_path}/Contents/Info.plist"
update_feed="$(/usr/libexec/PlistBuddy -c 'Print :TwainBridgeUpdateFeedURL' "${info_plist}")"
update_key="$(/usr/libexec/PlistBuddy -c 'Print :TwainBridgeUpdatePublicKey' "${info_plist}")"
python3 -c '
import base64, sys, urllib.parse
feed, key = sys.argv[1:]
parsed = urllib.parse.urlparse(feed)
if parsed.scheme.lower() != "https" or not parsed.hostname:
    raise SystemExit("Archived update feed must be an absolute HTTPS URL.")
try:
    decoded = base64.b64decode(key, validate=True)
except Exception as error:
    raise SystemExit("Archived update public key is not valid base64.") from error
if len(decoded) != 32:
    raise SystemExit("Archived update public key must decode to 32 bytes.")
' "${update_feed}" "${update_key}"

submission_zip="${release_root}/TwainBridge-notary-submission.zip"
ditto -c -k --keepParent "${application_path}" "${submission_zip}"
xcrun notarytool submit "${submission_zip}" --keychain-profile "${notary_profile}" --wait
xcrun stapler staple "${application_path}"
xcrun stapler validate "${application_path}"
spctl --assess --type execute --verbose=2 "${application_path}"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${application_path}/Contents/Info.plist")"
final_zip="${release_root}/TwainBridge-${version}-universal.zip"
ditto -c -k --keepParent "${application_path}" "${final_zip}"
shasum -a 256 "${final_zip}"
print "Release package: ${final_zip}"
