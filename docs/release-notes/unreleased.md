# Unreleased

## Improvements

- Administrators can provision `ManagedLicenseKey` through a macOS configuration profile or user-context script. TypeWhisper activates it automatically, reuses the activation, and displays organization-managed licensing controls. Includes the license and Keychain persistence fixes shipped in 1.6.1. See [the MDM deployment guide](../mdm/README.md). (#1314)

- Number formatting now offers Always, 10 and above (the default), and 100 and above under Settings → Dictation → Output Formatting. Smaller spoken whole numbers and ordinals keep their original wording. Negative numbers use their magnitude; decimals and recognized digit sequences still convert to digits. The threshold also applies when a workflow enables number normalization. Settings backups preserve both the number-normalization toggle and threshold. Existing digits are unchanged. (#1304)

## Fixes

- Escape used to cancel dictation is now consumed by TypeWhisper instead of reaching the target app and potentially dismissing a text field or navigating back. This applies during microphone startup, recording, and transcription, including both presses in double-Escape mode. Holding Escape does not count as a second press. Escape works normally again after cancellation and releasing the key. (#1303)

- Long dictations that a cloud provider such as Groq returns only partially no longer end silently as a success. After the final transcription, TypeWhisper compares the returned segments and the word count with the length of the recording. When the result looks incomplete, the text is still inserted, the notch shows a warning, the History entry is marked as possibly incomplete, and the recording is kept in Dictation Recovery under the existing retention setting so it can be transcribed again from there. Recordings that look complete are discarded as before, so nothing extra is stored in the normal case. Groq now receives dictionary terms as a short framed context sentence with a smaller budget instead of a bare comma-separated list; the new "Send dictionary terms to Groq" toggle in the Groq plugin settings is on by default and can turn them off. (#1352)
