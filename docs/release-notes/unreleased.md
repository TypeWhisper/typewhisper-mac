# Unreleased

- Audio ducking: Preserve the output volume from before microphone startup so stopping or cancelling dictation restores the original level on devices such as USB speakerphones, including cancellation before the first audio buffer and recording startup failures.
- Gemini plugin: Choose Verbatim or Smart transcription for live dictation and audio files. Verbatim is now the default and preserves fillers, repetitions, and spoken corrections; select Smart to keep the previous cleanup and formatting behavior.
- Gemini plugin 1.1.2: Reduce the wait after releasing the dictation hotkey, retain available text if finalization times out, and prepare a fresh Live connection for the next dictation. Unused connections close before they become too old to hand over safely.
- Recorder automation: Send successfully saved transcripts to Webhook Notifications or Script Runner with a separate, default-off option for each destination. The local API can retrieve completed manual, calendar, and API recordings after a restart, including retranscriptions. Webhook and Script Runner 1.2.0 require TypeWhisper 1.8.0.
