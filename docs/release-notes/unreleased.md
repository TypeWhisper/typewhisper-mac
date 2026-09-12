# Unreleased

## Fixes

- Escape used to cancel dictation is now consumed by TypeWhisper instead of reaching the target app and potentially dismissing a text field or navigating back. This applies during microphone startup, recording, and transcription, including both presses in double-Escape mode. Holding Escape does not count as a second press. Escape works normally again after cancellation and releasing the key. (#1303)
