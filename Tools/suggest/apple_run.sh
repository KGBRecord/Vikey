#!/bin/bash
# Apple's suggestion bar for a cases file, on a simulator with the English (US) keyboard only:
#   Tools/suggest/apple_run.sh <sim udid> <cases.json> <out.jsonl>
# Prints nothing to the keyboard's learning: the app sets the text, only the case's letters are typed.
set -euo pipefail
cd "$(dirname "$0")/AppleRef"
xcodegen generate -q
log="${3%.jsonl}.log"
TEST_RUNNER_CASES="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")" xcodebuild test -project AppleRef.xcodeproj -scheme AppleRef \
  -destination "id=$1" -derivedDataPath "${TMPDIR:-/tmp}/appleref-dd" -only-testing:AppleRefUITests/AppleRefUITests/testSuggestionBar \
  CODE_SIGNING_ALLOWED=NO > "$log" 2>&1 || true
grep '^SUGGEST' "$log" | cut -f2- > "$3"
echo "$(wc -l < "$3") cases read → $3"
