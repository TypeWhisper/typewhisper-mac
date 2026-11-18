import Foundation

// MARK: - Verbatim Transcripts

/// Whether the host needs the words as the engine heard them for the current
/// transcription.
///
/// Dictionary training compares the transcript with the word the user spoke,
/// so the host turns this on for it. An engine that can rewrite its transcript,
/// for example to remove filler words, then returns the verbatim text instead.
/// The value is task-local; read it in the task that runs `transcribe`, not in
/// a detached task.
public enum PluginVerbatimTranscript {
    @TaskLocal public static var isRequired = false
}
