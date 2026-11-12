#!/bin/sh
# Records the xcodebuild test output and the xcresulttool JSON of the sample package.
#
# Two runs are recorded:
# - out/: the sample as it is, with failing tests and a build warning in SampleKit.
# - out/compile-error/: a copy of the sample in /tmp/sci-sample-compile-error with a file of SampleKit that does not
#   compile. The sample in this directory is not changed.
cd "$(dirname "$0")" || exit 1
root="$PWD"

schemes=$(xcodebuild -list -json | /usr/bin/python3 -I -c 'import json,sys; d=json.load(sys.stdin); print("\n".join((d.get("workspace") or d.get("project") or {}).get("schemes", [])))')
echo "Schemes: $(echo $schemes)"
if echo "$schemes" | grep -qx "SampleApp-Package"; then
    scheme="SampleApp-Package"
else
    scheme=$(echo "$schemes" | head -1)
fi
echo "Using scheme: $scheme"

# record <package directory> <output directory>
record() {
    package="$1"
    out="$root/$2"
    mkdir -p "$out"
    rm -rf "$out/Sample.xcresult" "$out"/*.log "$out"/*.json

    (cd "$package" && xcodebuild test -scheme "$scheme" \
        -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
        -resultBundlePath "$out/Sample.xcresult" -enableCodeCoverage YES \
        > "$out/xcodebuild-test.log" 2>&1)
    echo "xcodebuild exit $? (65 expected) for $2"

    xcrun xcresulttool get test-results tests --path "$out/Sample.xcresult" > "$out/test-results-tests.json"
    xcrun xcresulttool get test-results summary --path "$out/Sample.xcresult" > "$out/test-results-summary.json"
    xcrun xcresulttool get build-results --path "$out/Sample.xcresult" --format json > "$out/build-results.json"

    echo "Lines in the log: $(wc -l < "$out/xcodebuild-test.log")"
    grep -E "Executed [0-9]+ tests|Test run with|TEST (SUCCEEDED|FAILED)|error:" "$out/xcodebuild-test.log" | tail -8
    grep -E '"(totalTestCount|failedTests|skippedTests|passedTests)"' "$out/test-results-summary.json"
}

record "$root" out

# The compile error is a new file, so the line of the error is fixed.
copy=/tmp/sci-sample-compile-error
rm -rf "$copy"
mkdir -p "$copy"
cp -R Package.swift Sources Tests "$copy/" || exit 1
printf 'public func brokenSample() -> Int {\n    "not an integer"\n}\n' > "$copy/Sources/SampleKit/Broken.swift"
record "$copy" out/compile-error
