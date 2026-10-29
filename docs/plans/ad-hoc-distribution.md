# Ad-hoc distribution

Status: **accepted**. Part of Phase 1 of the
[implementation plan](implementation-plan.md#phase-1-replace-bitrise): the
generic pieces of the first ported workflow, an internal ad-hoc deploy.

## Goal

A script can replace a typical ad-hoc deploy workflow of a workflow runner
with SwiftCI calls:

1. Set the build number and read the app's version.
2. Stamp the version on the app icon.
3. Install the signing assets with `fastlane match`, through the explicit
   fastlane fallback.
4. Archive the app and export an ad-hoc IPA.
5. Name the IPA after the version, build number, Git tag and commit.
6. Write the over-the-air (OTA) install files: a `manifest.plist` and an HTML
   install page whose `itms-services://` link installs the IPA on a
   registered device.
7. Send a Slack message.

Most of this exists: `Keychain.unlock`, `Icon.addText`, `Git`,
`Xcode.archiveAndExport`, `Plist`, `Slack.send`, `Bitrise.run` and
`Fastlane.match`. This plan adds the missing generic pieces. Each milestone is
independent and small, so that an adopting project can move its workflow
over one step at a time, outside-in (see
[Incremental adoption](incremental-adoption.md)), and use each piece as soon
as it lands.

## Non-goals

- Publishing the install files to a web server or object storage. This stays
  an [extension idea](../../README.md#extension-ideas). The script archives
  the files with its CI system, and the CI system serves them.
- An artifact-naming helper. A name is a project convention. Scripts build it
  from `Git.getCommitHash()`, `Git.getCommitTag()` and the version query in
  A1.
- Setting the build number through build settings (`CURRENT_PROJECT_VERSION`,
  `agvtool`). A1 writes the Info.plist only. Add the build-setting variant
  when a project needs it.
- Enterprise and App Store exports. `archiveAndExport` stays ad-hoc. App Store
  export and upload are the next Phase 1 workflow.

## A1: Version and build number

Changes, in `SwiftCIXcode`:

1. `Xcode.setBuildNumber(_ buildNumber: String, infoPlist: URL, step: String? = nil) async throws`,
   a static method. It writes `buildNumber` as the literal value of
   `CFBundleVersion` in the Info.plist and keeps the file's format. It does
   work, so it opens a step named "Set build number to 42". It does not
   validate the value: ad-hoc builds accept any string, for example `dev`,
   while App Store Connect requires numbers separated by periods. The doc
   comment says so. A missing or unreadable file is a `BuildError` that names
   the file.
2. `getBuildSettings(target: String? = nil)`. `xcodebuild -showBuildSettings`
   for a scheme returns one entry per target in the scheme, and today the
   first entry is used. With `target`, the entry whose `target` field matches
   is used. An unknown target is a `BuildError` that lists the available
   targets. Without `target`, the behavior is unchanged.
3. `getVersion(infoPlist: URL, target: String? = nil) async throws -> AppVersion`,
   an instance method and a query, so it opens no step. `AppVersion` has
   `marketingVersion` (`CFBundleShortVersionString`) and `buildNumber`
   (`CFBundleVersion`). A value that contains `$(NAME)` or `${NAME}` is
   resolved from the build settings of the scheme and configuration, for
   example `$(MARKETING_VERSION)`. Build settings are read only if a value
   needs them. A reference that the build settings do not define is a
   `BuildError` that names the variable and the file.

Tests (fixtures for the plist and the `-showBuildSettings -json` output,
through the process runner mock):

- `setBuildNumber` writes the value, keeps the other keys, and opens one step
  with its default name; `step:` renames it.
- A literal version and build number are returned without running
  `xcodebuild`.
- `$(NAME)` and `${NAME}` are resolved, from the requested target when there
  are several.
- An unknown target and an undefined variable fail with the messages above.

README.md: the capability row "Version and build number setting" becomes
Prototype. The `xcodebuild` and `Info.plist` rows of the Bitrise migration
table, if present, point to the new calls.

## A2: Over-the-air install files

Changes, in `SwiftCIXcode`, a new `OverTheAirInstall` type with static
methods. Both do work, so both open a step and take a final `step:`
parameter. Both write files that the user keeps, so callers usually pass
`Artifacts.url(_:)`.

1. `writeManifest(to url: URL, ipaURL: URL, bundleIdentifier: String, bundleVersion: String, title: String, step: String? = nil) async throws`
   writes the manifest property list: one item with a `software-package`
   asset at `ipaURL` and the metadata `bundle-identifier`, `bundle-version`,
   `kind` = `software` and `title`. It is written with
   `PropertyListSerialization` in XML format, so values are escaped.
2. `writeInstallPage(to url: URL, manifestURL: URL, title: String, step: String? = nil) async throws`
   writes an HTML page that redirects to
   `itms-services://?action=download-manifest&url=<manifestURL>` with a
   `meta refresh` and also shows the same link with `title` as its text, for
   browsers that block the redirect. `manifestURL` is percent-encoded as a
   query value, and the page's text and attributes are HTML-escaped.

`ipaURL` and `manifestURL` are web URLs where the CI system serves the files,
not file URLs. Only the output locations (`to:`) are file URLs. Composing a
web URL from a CI build URL is CI-specific and stays in the script. iOS
installs only over HTTPS, so a URL whose scheme is not `https` logs a warning
that says the install will not work on a device. It does not fail, because a
local test run often has no HTTPS URL.

Tests:

- The manifest decodes back to the expected structure, also with `&`, `<`
  and non-ASCII characters in the values.
- The install page contains the encoded manifest URL in both the redirect and
  the link, and escapes the title.
- A `http` URL logs one warning; an `https` URL logs none.
- Each call opens one step with its default name; `step:` renames it.

README.md: the capability table gets a row "Over-the-air install files
(`manifest.plist` and install page)", Prototype. The extension idea "Ad-hoc
and enterprise over-the-air install" keeps only publishing the files to a web
server or object storage. The generated-files table of the
[end-user documentation plan](end-user-documentation.md#d5-artifacts-and-generated-files)
lists both files when it is written.

## A3: fastlane fallback with Bundler and several app identifiers

Today `Fastlane.match` and `Fastlane.matchUpdate` run `fastlane` from `PATH`
with one app identifier. Projects usually pin fastlane in a `Gemfile` and run
it with `bundle exec`, and a match call often installs the profiles of many
apps at once.

Changes, in `SwiftCISigning`:

1. `appIdentifier: String` becomes `appIdentifiers: [String]`, passed to
   `--app_identifier` joined with commas. An empty list is a usage error. This
   is a breaking change of pre-1.0 API, listed in the release notes.
2. A new parameter `invocation: FastlaneInvocation = .direct`.
   `FastlaneInvocation` has two cases: `.direct` runs `fastlane`, and
   `.bundler(gemfile: URL? = nil)` runs `bundle exec fastlane`, with
   `BUNDLE_GEMFILE` set in the tool's environment when `gemfile` is given.
   The project chooses explicitly. SwiftCI never looks for a `Gemfile` and
   never installs gems.
3. A new parameter `environment: [String: ToolEnvironmentValue] = [:]`,
   passed to the tool, for variables such as `PATH`, `LC_ALL` or the match
   password. A `Secret` value stays out of the arguments and the log.
4. A default output filter, as every integration has: it keeps errors,
   warnings, the installed certificate and profile summary and the final
   result, and hides the rest. The full log keeps everything. The filter is
   tested against a recorded `fastlane match --readonly` run, with every
   identifier, team, URL and name in the recording replaced by placeholders
   before it is committed.
5. With more than one identifier, the default step name says how many, for
   example "Install signing assets with fastlane match (adhoc, 25 app
   identifiers)", instead of listing them.

Tests:

- The arguments for one and several identifiers, for `.direct` and for
  `.bundler` with and without a Gemfile.
- `environment` reaches the tool, and a `Secret` in it is not in the
  arguments or the log.
- An empty identifier list fails with a usage error before any process runs.
- The filter keeps and hides the expected lines of the recording.

README.md: the [native implementations and explicit
fallbacks](../../README.md#native-implementations-and-explicit-fallbacks)
section mentions `.bundler`, next to the rule that the project provides
fastlane.

## Order

A1, A2 and A3 are independent and can land in any order, each in its own
change. The adopting project needs A1 for its build number step, A2 for its
install files step and A3 for its match step, so the order follows its
progress. Its plan uses a local SwiftCI checkout until it runs in production
CI. From then on, a project step that needs one of these milestones waits for
a tagged release that contains it.

## Risks

- **Conditional build settings.** Settings such as
  `PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]` apply only for the device
  SDK, and `-showBuildSettings` without an SDK or destination may report the
  unconditional value. This affects `getVersion` only if a version uses such
  a setting, but `archiveAndExport` already reads the provisioning profile
  this way. The adopting project's archive parity run checks it. If it is
  wrong, `getBuildSettings` passes `-destination generic/platform=iOS`.
- **Install page behavior.** Mobile Safari's handling of `itms-services`
  redirects has changed between iOS versions. The visible link is the
  fallback, and the adopting project's parity run installs the app from the
  page on a device.

## Decisions

- Generating the OTA install files is first-party, in `SwiftCIXcode`.
  Publishing them stays an extension idea.
- The build number is written to the Info.plist only, as a literal value.
- No artifact-naming helper. Scripts compose names from existing queries.
- The fastlane invocation is explicit (`.direct` or `.bundler`). It is never
  inferred from the presence of a `Gemfile`.
- Web URLs in the OTA API are `URL`s like file paths, but they are never file
  URLs. A non-HTTPS URL is a warning, not a failure.

## Open questions

None at the moment.
