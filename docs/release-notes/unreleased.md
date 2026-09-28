# Unreleased

## Improvements

- Dictation Recovery keeps the last three successful dictations for up to 24 hours, so an incomplete provider response can be retried even when it looks successful. The Immediately retention setting disables this buffer as well. Groq's settings now let you disable dictionary context without changing post-transcription corrections. Final-transcription diagnostics include audio duration, word counts, and segment timing without logging audio, prompt contents, or transcript text. (#1352)

- Administrators can provision `ManagedLicenseKey` through a macOS configuration profile or user-context script. TypeWhisper activates it automatically, reuses the activation, and displays organization-managed licensing controls. Includes the license and Keychain persistence fixes shipped in 1.6.1. See [the MDM deployment guide](../mdm/README.md). (#1314)

- Number formatting now offers Always, 10 and above (the default), and 100 and above under Settings → Dictation → Output Formatting. Smaller spoken whole numbers and ordinals keep their original wording. Negative numbers use their magnitude; decimals and recognized digit sequences still convert to digits. The threshold also applies when a workflow enables number normalization. Settings backups preserve both the number-normalization toggle and threshold. Existing digits are unchanged. (#1304)

## Fixes

- Escape used to cancel dictation is now consumed by TypeWhisper instead of reaching the target app and potentially dismissing a text field or navigating back. This applies during microphone startup, recording, and transcription, including both presses in double-Escape mode. Holding Escape does not count as a second press. Escape works normally again after cancellation and releasing the key. (#1303)
