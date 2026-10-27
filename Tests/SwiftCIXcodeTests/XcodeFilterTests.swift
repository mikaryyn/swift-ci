@testable import SwiftCIXcode
import SwiftCI
import Testing

@Suite struct XcodeFilterTests {
    @Test(arguments: [
        "/work/MyApp.xcodeproj: error: Missing package product 'MyLibrary' (in target 'MyApp' from project 'MyApp')",
        "/work/MyApp/View.swift:12:5: error: cannot find 'foo' in scope",
        "error: Signing for \"MyApp\" requires a development team.",
        "xcodebuild: error: The project named \"MyApp\" does not contain a scheme named \"Other\".",
        "fatal error: 'Header.h' file not found",
        "/work/MyApp/View.swift:20:9: warning: variable 'x' was never used",
        "ld: warning: ignoring duplicate libraries: '-lc++'",
        "warning: Run script build phase 'Lint' will be run during every build",
        "** BUILD DOCUMENTATION FAILED **",
        "** ARCHIVE FAILED **",
    ])
    func errorsWarningsAndFailuresAreShownUnchanged(line: String) {
        #expect(Xcode.xcodebuildFilter(line) == line)
    }

    @Test(arguments: [
        "",
        "   ",
        "Command line invocation:",
        "ComputeTargetDependencyGraph",
        "note: Building targets in dependency order",
        "CompileSwift normal arm64 /work/MyApp/View.swift (in target 'MyApp' from project 'MyApp')",
        "    cd /work",
        "Build description path: /work/DerivedData/XCBuildData/abc.xcbuilddata",
        "2026-01-01 09:12:43.414 xcodebuild[1:2] [MT] IDESchemeActionsInvocationRecord: Device is missing operatingSystemVersion.",
        "objc[1]: Class X is implemented in both /usr/lib/libauthinstall.dylib and /usr/lib/other.dylib.",
        "The following build commands failed:",
    ])
    func otherLinesAreHidden(line: String) {
        #expect(Xcode.xcodebuildFilter(line) == nil)
    }

    @Test(arguments: [("** BUILD SUCCEEDED **", "BUILD"), ("** EXPORT SUCCEEDED **", "EXPORT"),
                      ("** BUILD DOCUMENTATION SUCCEEDED **", "BUILD DOCUMENTATION")])
    func successIsShownAsFinished(line: String, action: String) {
        #expect(Xcode.xcodebuildFilter(line) == "\(action) finished".success)
    }
}
