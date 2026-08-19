fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Mac

### mac screenshots

```sh
[bundle exec] fastlane mac screenshots
```

Capture deterministic localized macOS screenshots

### mac screenshots_publish

```sh
[bundle exec] fastlane mac screenshots_publish
```

Promote the generated English screenshots into the README assets

### mac screenshots_release

```sh
[bundle exec] fastlane mac screenshots_release
```

Capture every locale, publish English, and validate the README gallery

### mac screenshots_check

```sh
[bundle exec] fastlane mac screenshots_check
```

Validate the committed README screenshot gallery

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
