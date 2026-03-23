# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in TypeWhisper, please report it responsibly.

**Do not open a public issue.** Instead, email security concerns to: **security@typewhisper.com**

You can also use [GitHub's private vulnerability reporting](https://github.com/TypeWhisper/typewhisper-mac/security/advisories/new).

We will acknowledge your report within 48 hours and aim to provide a fix within 7 days for critical issues.

## Scope

TypeWhisper handles sensitive data including:
- Microphone audio
- API keys (stored in macOS Keychain)
- AppleScript automation (browser URL detection)
- Local HTTP API server

Issues in these areas are especially relevant.

## Security Boundaries

- The local HTTP API binds to `127.0.0.1` only.
- The API server is disabled by default and must be enabled explicitly in Settings > Advanced.
- API keys are stored in the macOS Keychain and must never appear in exported diagnostics.
- Support diagnostics are exported as a privacy-safe JSON report and exclude API keys, audio payloads, and transcription history.

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest release | Yes |
| Current release candidate / preview build | Best effort |
| Older versions | No |
