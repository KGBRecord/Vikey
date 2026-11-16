#!/bin/bash
# Vikey's suggestion bar for a cases file (iOS/Tests/SuggestionBenchTests, the real keyboard in English):
#   Tools/suggest/vikey_run.sh <sim udid> <cases.json> <out.jsonl>
set -euo pipefail
cd "$(dirname "$0")/../../iOS"
xcodegen generate -q
log="${3%.jsonl}.log"
TEST_RUNNER_CASES="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")" xcodebuild test -project VikeyiOS.xcodeproj -scheme Vikey \
  -destination "id=$1" -derivedDataPath "${TMPDIR:-/tmp}/vksuggest-dd" -only-testing:VikeyTests/SuggestionBenchTests \
  CODE_SIGNING_ALLOWED=NO > "$log" 2>&1 || { tail -20 "$log"; exit 1; }
grep "^VIKEY$(printf '\t')" "$log" | cut -f2- > "$3"
echo "$(wc -l < "$3") cases read → $3"
