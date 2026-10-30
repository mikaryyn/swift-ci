#!/bin/sh
# Records the xcodebuild test output and the xcresulttool JSON of the sample package into out/.
cd "$(dirname "$0")" || exit 1
mkdir -p out
rm -rf out/Sample.xcresult out/*.log out/*.json

schemes=$(xcodebuild -list -json | /usr/bin/python3 -I -c 'import json,sys; d=json.load(sys.stdin); print("\n".join((d.get("workspace") or d.get("project") or {}).get("schemes", [])))')
echo "Schemes: $(echo $schemes)"
if echo "$schemes" | grep -qx "SampleApp-Package"; then
    scheme="SampleApp-Package"
else
    scheme=$(echo "$schemes" | head -1)
fi
echo "Using scheme: $scheme"

xcodebuild test -scheme "$scheme" \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -resultBundlePath "$PWD/out/Sample.xcresult" -enableCodeCoverage YES \
    > out/xcodebuild-test.log 2>&1
echo "xcodebuild exit $? (65 expected)"

xcrun xcresulttool get test-results tests --path out/Sample.xcresult > out/test-results-tests.json
xcrun xcresulttool get test-results summary --path out/Sample.xcresult > out/test-results-summary.json

echo "Lines in the log: $(wc -l < out/xcodebuild-test.log)"
grep -E "Executed [0-9]+ tests|Test run with|TEST (SUCCEEDED|FAILED)" out/xcodebuild-test.log | tail -5
grep -E '"(totalTestCount|failedTests|skippedTests|passedTests)"' out/test-results-summary.json
