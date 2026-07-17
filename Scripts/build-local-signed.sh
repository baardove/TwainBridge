#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
project_directory="${script_directory:h}"
derived_data="${TWAINBRIDGE_LOCAL_SIGNED_DERIVED_DATA:-${project_directory}/.build/LocalSignedDerivedData}"
development_team="${TWAINBRIDGE_DEVELOPMENT_TEAM:-FGA3Z9LLS2}"

command -v xcodegen >/dev/null || {
  print -u2 "XcodeGen is required. Install it before building TwainBridge."
  exit 2
}

security find-identity -v -p codesigning | rg -q 'Apple Development:' || {
  print -u2 "A valid Apple Development signing identity is required for stable camera and Keychain permissions."
  exit 2
}

cd "${project_directory}"
xcodegen generate
xcodebuild -quiet \
  -project TwainBridge.xcodeproj \
  -scheme TwainBridge \
  -configuration Release \
  -derivedDataPath "${derived_data}" \
  -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY='Apple Development' \
  DEVELOPMENT_TEAM="${development_team}" \
  build

application_path="${derived_data}/Build/Products/Release/TwainBridge.app"
signature="$(codesign -dv --verbose=4 "${application_path}" 2>&1)"

codesign --verify --deep --strict --verbose=2 "${application_path}"
rg -q '^Identifier=com\.45webs\.TwainBridge$' <<<"${signature}" || {
  print -u2 "The signed app has the wrong code-signing identifier."
  exit 3
}
rg -q "^TeamIdentifier=${development_team}$" <<<"${signature}" || {
  print -u2 "The signed app does not use the expected development team."
  exit 3
}
codesign -d --entitlements :- "${application_path}" 2>/dev/null \
  | rg -q 'com\.apple\.security\.device\.camera' || {
    print -u2 "The signed app is missing its camera entitlement."
    exit 3
  }

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${application_path}/Contents/Info.plist")"
print "Signed local build passed: TwainBridge ${version}, TeamIdentifier ${development_team}."
print "Signed app: ${application_path}"
