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

- **macOS 15.0+** required
- **Swift 6** with strict concurrency
- Debug builds use a separate data directory (`TypeWhisper-Dev`) and keychain prefix, so they don't interfere with release builds

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

## Reporting Issues

Use the [issue templates](https://github.com/TypeWhisper/typewhisper-mac/issues/new/choose) for bug reports and feature requests.

## License

By contributing, you agree that your contributions will be licensed under GPLv3.
