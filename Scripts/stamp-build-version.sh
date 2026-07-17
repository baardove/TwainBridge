#!/bin/zsh
set -euo pipefail

counter_file="${SRCROOT}/Config/BuildNumber.txt"
lock_directory="${SRCROOT}/Config/.build-number.lock"
temporary_counter="${counter_file}.tmp.${$}"
attempt=0

while ! mkdir "${lock_directory}" 2>/dev/null; do
  attempt=$((attempt + 1))
  if (( attempt > 200 )); then
    print -u2 "Timed out waiting for the TwainBridge build-number lock."
    exit 1
  fi
  sleep 0.05
done

cleanup() {
  rm -f "${temporary_counter}"
  rmdir "${lock_directory}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

current_build="$(tr -d '[:space:]' < "${counter_file}")"
if [[ ! "${current_build}" =~ '^[0-9]+$' ]]; then
  print -u2 "Invalid build number in ${counter_file}: ${current_build}"
  exit 1
fi

next_build=$((current_build + 1))
print -r -- "${next_build}" > "${temporary_counter}"
mv "${temporary_counter}" "${counter_file}"

info_plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [[ ! -f "${info_plist}" ]]; then
  print -u2 "Built Info.plist was not found at ${info_plist}."
  exit 1
fi

short_version="1.0.${next_build}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${short_version}" "${info_plist}" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${short_version}" "${info_plist}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${next_build}" "${info_plist}" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${next_build}" "${info_plist}"

print "Stamped TwainBridge ${short_version} (build ${next_build})"
