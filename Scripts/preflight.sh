#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
project_directory="${script_directory:h}"
debug_data="${TWAINBRIDGE_DEBUG_DERIVED_DATA:-${project_directory}/.build/DerivedData}"
release_data="${TWAINBRIDGE_RELEASE_DERIVED_DATA:-${project_directory}/.build/ReleaseDerivedData}"
runtime_directory="$(mktemp -d -t twainbridge-preflight.XXXXXX)"
runtime_log="${runtime_directory}/launch.log"
test_log="${runtime_directory}/tests.log"
runtime_pid=""

cleanup() {
  if [[ -n "${runtime_pid}" ]] && kill -0 "${runtime_pid}" 2>/dev/null; then
    kill -TERM "${runtime_pid}" 2>/dev/null || true
    wait "${runtime_pid}" 2>/dev/null || true
  fi
  rm -rf "${runtime_directory}"
}
trap cleanup EXIT INT TERM

cd "${project_directory}"

command -v xcodegen >/dev/null || {
  print -u2 "XcodeGen is required. Install it before running preflight."
  exit 2
}
command -v jq >/dev/null || {
  print -u2 "jq is required to validate test and localization output."
  exit 2
}

jq empty Resources/Localizable.xcstrings
python3 -c 'compile(open("ReferenceReceiver/server.py", "rb").read(), "ReferenceReceiver/server.py", "exec")'
python3 -c 'compile(open("DemoReceiver/server.py", "rb").read(), "DemoReceiver/server.py", "exec")'
python3 -m unittest discover -s DemoReceiver -p 'test_*.py'
zsh -n Scripts/preflight.sh Scripts/build-local-signed.sh Scripts/release.sh Scripts/test-reference-receiver.sh
xcrun swiftc -typecheck Scripts/sign-update-manifest.swift
Scripts/test-reference-receiver.sh
xcodegen generate

xcodebuild -quiet \
  -project TwainBridge.xcodeproj \
  -scheme TwainBridge \
  -configuration Debug \
  -derivedDataPath "${debug_data}" \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing

test_product="${debug_data}/Build/Products/Debug/TwainBridge.app"
test_bundle="${test_product}/Contents/PlugIns/TwainBridgeTests.xctest"
set +e
DYLD_FALLBACK_LIBRARY_PATH="${test_product}/Contents/MacOS" \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xctest "${test_bundle}" 2>&1 | tee "${test_log}"
test_status="${pipestatus[1]}"
set -e
test_result="$(rg 'Executed [0-9]+ tests, with [0-9]+ failures' "${test_log}" | tail -1)"
passed_tests="$(sed -E 's/.*Executed ([0-9]+) tests.*/\1/' <<<"${test_result}")"
if [[ "${test_status}" != 0 \
   || -z "${test_result}" \
   || "${test_result}" != *"with 0 failures (0 unexpected)"* \
   || "${test_result}" == *"skipped"* ]]; then
  print -u2 "Test preflight failed. Final XCTest result: ${test_result:-missing}"
  exit 3
fi

xcodebuild -quiet \
  -project TwainBridge.xcodeproj \
  -scheme TwainBridge \
  -configuration Release \
  -derivedDataPath "${release_data}" \
  -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

application_path="${release_data}/Build/Products/Release/TwainBridge.app"
executable_path="${application_path}/Contents/MacOS/TwainBridge"
info_plist="${application_path}/Contents/Info.plist"
architectures="$(lipo -archs "${executable_path}")"
minimum_macos="$(otool -l "${executable_path}" | awk '/minos/{print $2; exit}')"
agent_app="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "${info_plist}")"
icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "${info_plist}")"
camera_usage="$(/usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' "${info_plist}")"
allows_local_http="$(/usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsLocalNetworking' "${info_plist}")"
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${info_plist}")"
bundle_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${info_plist}")"
source_build="$(tr -d '[:space:]' < "${project_directory}/Config/BuildNumber.txt")"

[[ " ${architectures} " == *" arm64 "* && " ${architectures} " == *" x86_64 "* ]] || {
  print -u2 "Release is not universal: ${architectures}"
  exit 4
}
[[ "${minimum_macos}" == "15.0" ]] || {
  print -u2 "Unexpected deployment target: ${minimum_macos}"
  exit 4
}
[[ "${agent_app}" == "true" ]] || {
  print -u2 "LSUIElement is not enabled; TwainBridge would not be status-bar-only."
  exit 4
}
[[ "${icon_name}" == "AppIcon" \
   && -f "${application_path}/Contents/Resources/AppIcon.icns" \
   && -f "${application_path}/Contents/Resources/Assets.car" ]] || {
  print -u2 "Compiled app icon resources are missing."
  exit 4
}
otool -L "${executable_path}" | rg -q 'ImageCaptureCore.framework' || {
  print -u2 "The native ImageCaptureCore scanner provider is not linked."
  exit 4
}
otool -L "${executable_path}" | rg -q 'Carbon.framework' || {
  print -u2 "The global Carbon hotkey provider is not linked."
  exit 4
}
otool -L "${executable_path}" | rg -q 'AVFoundation.framework' || {
  print -u2 "The AVFoundation webcam provider is not linked."
  exit 4
}
[[ -n "${camera_usage}" ]] || {
  print -u2 "The camera privacy usage description is missing."
  exit 4
}
[[ "${allows_local_http}" == "true" ]] || {
  print -u2 "ATS local-network HTTP support is missing from the release Info.plist."
  exit 4
}
[[ "${bundle_build}" == "${source_build}" && "${short_version}" == "1.0.${bundle_build}" ]] || {
  print -u2 "Version stamp mismatch: bundle=${short_version} (${bundle_build}), counter=${source_build}."
  exit 4
}
rg -q '<key>com.apple.security.device.camera</key>' Config/TwainBridge.entitlements || {
  print -u2 "The hardened-runtime camera entitlement is missing."
  exit 4
}

"${executable_path}" >"${runtime_log}" 2>&1 &
runtime_pid=$!
resident_kib=""
for elapsed_second in 1 2 3 4 5; do
  sleep 1
  if ! kill -0 "${runtime_pid}" 2>/dev/null; then
    print -u2 "Release exited during launch smoke test."
    sed -n '1,120p' "${runtime_log}" >&2
    exit 5
  fi
  if [[ "${elapsed_second}" == 3 ]]; then
    resident_kib="$(ps -o rss= -p "${runtime_pid}" | tr -d ' ')"
  fi
done
[[ -n "${resident_kib}" && "${resident_kib}" -lt 153600 ]] || {
  print -u2 "Release process memory exceeds 150 MiB after three seconds: ${resident_kib:-unknown} KiB."
  exit 5
}
kill -TERM "${runtime_pid}"
wait "${runtime_pid}" 2>/dev/null || true
runtime_pid=""

print "Preflight passed: TwainBridge ${short_version}, ${passed_tests} tests, ${architectures}, macOS ${minimum_macos}+, LSUIElement, AppIcon, ATS local-network HTTP, ImageCaptureCore, AVFoundation webcam provider, Carbon hotkeys, ${resident_kib} KiB process RSS after three seconds, five-second stability smoke test."
print "Release bundle: ${application_path}"
print "This preflight bundle is unsigned. Use Scripts/build-local-signed.sh for an installable local build with persistent camera and Keychain permissions."
