#!/usr/bin/env bash
# Uploaded APKs must install through Files, which rejects test-only packages.
set -euo pipefail
apk=${1:?usage: check-installable-apk.sh app.apk}
sdk_aapt=$(command -v aapt || true)
if [[ -z "$sdk_aapt" ]]; then
  for candidate in "${ANDROID_HOME:?Set ANDROID_HOME}"/build-tools/*/aapt; do
    if [[ -x "$candidate" ]]; then sdk_aapt=$candidate; fi
  done
fi
if [[ -z "$sdk_aapt" ]]; then
  echo 'Android build-tools aapt is required to check the APK.' >&2
  exit 1
fi
badging=$("$sdk_aapt" dump badging "$apk")
test_only=$(printf '%s\n' "$badging" | sed -n "s/^testOnly='\(.*\)'$/\1/p")
case "$test_only" in
  ''|0|false) echo 'APK is not marked test-only.' ;;
  *) echo 'APK is marked android:testOnly and cannot be installed through Files.' >&2; exit 1 ;;
esac
