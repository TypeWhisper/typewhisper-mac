# Contributing to TypeWhisper

Thanks for your interest in contributing!

## Getting Started

1. Fork the repository and clone it
2. Open `TypeWhisper.xcodeproj` in Xcode 16+
3. SPM dependencies resolve automatically on first build
4. Build and run (Cmd+R) - the app appears as a menu bar icon

## Code Signing (Optional)

The project builds without any signing setup using ad-hoc signing.

To use your own signing identity:
```
echo 'DEVELOPMENT_TEAM = YOUR_TEAM_ID' > CodeSigning.local.xcconfig
```

## Development Setup

- **Product runtime support:** macOS 14.0+
- **Contributor machine:** macOS 15.0+ recommended for the current Xcode toolchain
- **Swift 6** with strict concurrency
- Debug builds use a separate data directory (`TypeWhisper-Dev`) and keychain prefix, so they don't interfere with release builds
- Debug builds produce `TypeWhisper Dev.app` (bundle ID `com.typewhisper.mac.dev`, Swift module still `TypeWhisper`), so macOS privacy lists show them separately from the release `TypeWhisper.app`

## Pull Requests

1. Create a feature branch from `main`
2. Keep changes focused - one feature or fix per PR
3. Test your changes manually and run the automated checks
4. Fill out the PR template (Summary + Test Plan)
5. PRs are squash-merged into `main`

Recommended checks:

```bash
xcodebuild test -project TypeWhisper.xcodeproj -scheme TypeWhisper -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
swift test --package-path TypeWhisperPluginSDK
```

## Code Style

- Follow existing patterns in the codebase
- MVVM architecture with `ServiceContainer` for dependency injection
- Localization: use `String(localized:)` for all user-facing strings
- SwiftData for persistence, Combine for reactive updates

## Mac App Store Edition

The Mac App Store edition builds the same sources from `appstore-project.yml`
(XcodeGen) with the `APPSTORE` compilation condition, the App Sandbox and the
first-party plugins listed there. CI compiles it for every pull request.
Code that the sandbox cannot run (launching processes, Apple Events,
Accessibility access to other apps, downloading code) needs an `#if APPSTORE`
alternative; keep such blocks small and explain them in a comment. Details,
build commands and the plugin list are in
[docs/appstore/README.md](docs/appstore/README.md).

## Credentials and Test Fixtures

Never commit real credentials, including revoked credentials copied from production.
Use clearly non-functional placeholders such as `test-key` or `fixture-token` in tests
and generated examples. Do not generate realistic provider tokens unless the test
specifically requires their format. Keep such tests isolated and explain why the
fixture cannot authenticate.

GitHub push protection blocks supported secret patterns. If a push is rejected,
remove the credential from every affected commit before retrying; a later deletion
commit does not remove it from history. Follow the
[maintainer runbook](docs/secret-scanning.md) for remediation and exceptional bypasses.

## Reporting Issues

Use the [issue templates](https://github.com/TypeWhisper/typewhisper-mac/issues/new/choose) for bug reports and feature requests.

## License

Contributions to the open-source project are distributed under GPLv3.
TypeWhisper also offers commercial licenses. Our shared
[Contributor License Agreement](https://github.com/TypeWhisper/.github/blob/main/CLA.md)
lets contributors retain ownership while granting the rights needed for both
open-source and commercial distribution.

Read the [organization-wide contribution rules](https://github.com/TypeWhisper/.github/blob/main/CONTRIBUTING.md)
and the agreement at [app.typewhisper.com/cla](https://app.typewhisper.com/cla).
You can open a pull request before signing. Before it can be merged, each
contributor must be covered by the current agreement and the `TypeWhisper CLA`
check must pass. Sign in with GitHub, read and explicitly accept the agreement,
and select any already-open pull requests you want it to cover. The check runs
again after acceptance. One acceptance covers future contributions across all
participating TypeWhisper projects for that agreement version.

A pull request submission does not itself record acceptance, and previously
merged contributions are reviewed separately. Employer authorization and
third-party licenses still apply.
