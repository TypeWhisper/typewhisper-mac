# Release Checklist

## Vor dem RC

- `xcodebuild test -project TypeWhisper.xcodeproj -scheme TypeWhisper -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
- `swift test --package-path TypeWhisperPluginSDK`
- `xcodebuild -project TypeWhisper.xcodeproj -scheme TypeWhisper -configuration Release -derivedDataPath build -destination 'generic/platform=macOS' CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
- `bash scripts/check_first_party_warnings.sh build.log`
- README, Security Policy und Support-Matrix pruefen

## RC Smoke-Checks

- Fresh install
- Permission recovery
- Erste Dictation
- Datei-Transkription
- Prompt-Aktion
- History edit/export
- Profile-Matching
- Plugin enable/disable
- CLI und HTTP API lokal pruefen
- Upgrade von `0.14.x`

## Vor `1.0.0`

- `1.0.0-rc1` mehrere Tage auf echten Maschinen beobachten
- Keine offenen P0/P1-Bugs im Kernworkflow
- Release Notes aktualisieren
- DMG, Appcast und Homebrew-Update pruefen
