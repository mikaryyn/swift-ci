# SwiftCI

A continuous integration toolkit implemented 100% with Swift.

## Motivation

Allow easy writing of continuous integration workflows by replacing a set of 
continuous integration tools that have many dependencies with a simplified
toolkit which requires only a Swift compiler.

## Project status

Early testing; works but APIs are not finished and there's no documentation.

## What it does?

- Runs multi-command build scripts that can be used in CI environment.
- Produces pretty-printed logging of output with filtering, colors and HTML output. 
- Builds and archives Xcode projects.
- Uploads builds to App Store Connect.
- Runs custom shell scripts and other tools.

## What it doesn't do?

- SwiftCI is not a complete build system such as xcodebuild, make, Ant, Gradle, etc.
- It doesn't contain a large number of ready integrations with 3rd party tools.
