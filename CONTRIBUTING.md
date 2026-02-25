# Contributing to TypeWhisper

Thanks for your interest in contributing!

## Getting Started

1. Fork the repository and clone it
2. Open `TypeWhisper.xcodeproj` in Xcode 16+
3. SPM dependencies resolve automatically on first build
4. Build and run (Cmd+R) - the app appears as a menu bar icon

## Development Setup

- **macOS 15.0+** required
- **Swift 6** with strict concurrency
- Debug builds use a separate data directory (`TypeWhisper-Dev`) and keychain prefix, so they don't interfere with release builds

## Pull Requests

1. Create a feature branch from `main`
2. Keep changes focused - one feature or fix per PR
3. Test your changes manually
4. Fill out the PR template (Summary + Test Plan)
5. PRs are squash-merged into `main`

## Code Style

- Follow existing patterns in the codebase
- MVVM architecture with `ServiceContainer` for dependency injection
- Localization: use `String(localized:)` for all user-facing strings
- SwiftData for persistence, Combine for reactive updates

## Reporting Issues

Use the [issue templates](https://github.com/TypeWhisper/typewhisper-mac/issues/new/choose) for bug reports and feature requests.

## License

By contributing, you agree that your contributions will be licensed under GPLv3.
