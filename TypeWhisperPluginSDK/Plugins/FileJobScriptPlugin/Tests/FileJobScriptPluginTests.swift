import Foundation
import TypeWhisperPluginSDK
import XCTest
@testable import FileJobScriptPlugin

final class FileJobScriptPluginTests: XCTestCase {
    private var cleanupURLs: [URL] = []

    override func tearDown() {
        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupURLs.removeAll()
        super.tearDown()
    }

    func testTimeoutSecondsClampToFileJobBounds() {
        XCTAssertEqual(FileJobScriptConfig(command: "true", timeoutSeconds: 1).effectiveTimeoutSeconds, 5)
        XCTAssertEqual(FileJobScriptConfig(command: "true", timeoutSeconds: 120).effectiveTimeoutSeconds, 120)
        XCTAssertEqual(FileJobScriptConfig(command: "true", timeoutSeconds: 9_000).effectiveTimeoutSeconds, 3_600)
    }

    func testStdoutReceivesArtifactOnStdinAndReplacesContent() async throws {
        let outputURL = try makeOutputURL()
        let context = makeContext(outputPath: outputURL.path)
        let artifact = FileJobArtifact(fileExtension: "txt", content: "hello")
        let script = FileJobScriptConfig(name: "Append", command: "cat; printf ' processed'")

        let result = await FileJobScriptRunner().execute(script: script, artifact: artifact, context: context)

        XCTAssertNil(result.errorMessage)
        XCTAssertTrue(result.didChangeArtifact)
        XCTAssertFalse(result.wroteOutputPath)
        XCTAssertEqual(result.artifact.content, "hello processed")
    }

    func testEnvironmentIncludesWatchFolderContextAndSidecarPaths() async throws {
        let outputURL = try makeOutputURL(fileExtension: "srt")
        let context = makeContext(outputPath: outputURL.path)
        let artifact = FileJobArtifact(fileExtension: "srt", content: "default")
        let command = #"""
        printf "%s|%s|%s|%s|%s|%s|%s|%s" \
          "$TYPEWHISPER_JOB_KIND" \
          "$TYPEWHISPER_SOURCE_FILE_PATH" \
          "$TYPEWHISPER_SOURCE_FILE_NAME" \
          "$TYPEWHISPER_OUTPUT_DIR" \
          "$TYPEWHISPER_OUTPUT_PATH" \
          "$TYPEWHISPER_OUTPUT_FORMAT" \
          "$TYPEWHISPER_ENGINE_ID" \
          "$TYPEWHISPER_TRANSCRIPT_JSON_PATH"
        """#
        let script = FileJobScriptConfig(name: "Env", command: command)

        let result = await FileJobScriptRunner().execute(script: script, artifact: artifact, context: context)
        let parts = result.artifact.content.split(separator: "|", omittingEmptySubsequences: false).map(String.init)

        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(parts[0], "watch-folder")
        XCTAssertEqual(parts[1], "/tmp/in/meeting.wav")
        XCTAssertEqual(parts[2], "meeting.wav")
        XCTAssertEqual(parts[3], outputURL.deletingLastPathComponent().path)
        XCTAssertEqual(parts[4], outputURL.path)
        XCTAssertEqual(parts[5], "srt")
        XCTAssertEqual(parts[6], "whisperkit")
        XCTAssertTrue(parts[7].hasSuffix("transcript.json"))
    }

    func testWritesTranscriptAndSegmentsJSONSidecars() async throws {
        let outputURL = try makeOutputURL()
        let context = makeContext(outputPath: outputURL.path)
        let script = FileJobScriptConfig(
            name: "Sidecars",
            command: #"""
            printf "TRANSCRIPT\n"
            cat "$TYPEWHISPER_TRANSCRIPT_JSON_PATH"
            printf "\nSEGMENTS\n"
            cat "$TYPEWHISPER_SEGMENTS_JSON_PATH"
            """#
        )

        let result = await FileJobScriptRunner().execute(
            script: script,
            artifact: FileJobArtifact(fileExtension: "md", content: "default"),
            context: context
        )

        XCTAssertNil(result.errorMessage)
        XCTAssertTrue(result.artifact.content.contains(#""text":"Speaker A: Hello""#))
        XCTAssertTrue(result.artifact.content.contains(#""detected_language":"en""#))
        XCTAssertTrue(result.artifact.content.contains(#""engine_id":"whisperkit""#))
        XCTAssertTrue(result.artifact.content.contains(#""speaker":"Speaker A""#))
        XCTAssertTrue(result.artifact.content.contains(#""speaker_confidence":0.91"#))
    }

    func testEmptyStdoutUsesScriptWrittenOutputPath() async throws {
        let outputURL = try makeOutputURL()
        let context = makeContext(outputPath: outputURL.path)
        let artifact = FileJobArtifact(fileExtension: "txt", content: "default")
        let script = FileJobScriptConfig(
            name: "Write file",
            command: #"printf 'from file' > "$TYPEWHISPER_OUTPUT_PATH""#
        )

        let result = await FileJobScriptRunner().execute(script: script, artifact: artifact, context: context)

        XCTAssertNil(result.errorMessage)
        XCTAssertTrue(result.didChangeArtifact)
        XCTAssertTrue(result.wroteOutputPath)
        XCTAssertEqual(result.artifact.content, "from file")
    }

    func testNonZeroExitFallsBackToInputArtifact() async throws {
        let outputURL = try makeOutputURL()
        let context = makeContext(outputPath: outputURL.path)
        let artifact = FileJobArtifact(fileExtension: "txt", content: "default")
        let script = FileJobScriptConfig(name: "Broken", command: "printf 'ignored'; exit 2")

        let result = await FileJobScriptRunner().execute(script: script, artifact: artifact, context: context)

        XCTAssertFalse(result.didChangeArtifact)
        XCTAssertFalse(result.wroteOutputPath)
        XCTAssertEqual(result.artifact, artifact)
        XCTAssertEqual(result.errorMessage, "Exit code 2")
    }

    func testTimeoutFallsBackToInputArtifact() async throws {
        let outputURL = try makeOutputURL()
        let context = makeContext(outputPath: outputURL.path)
        let artifact = FileJobArtifact(fileExtension: "txt", content: "default")
        let script = FileJobScriptConfig(name: "Slow", command: "sleep 20; printf 'ignored'", timeoutSeconds: 5)

        let result = await FileJobScriptRunner().execute(script: script, artifact: artifact, context: context)

        XCTAssertFalse(result.didChangeArtifact)
        XCTAssertFalse(result.wroteOutputPath)
        XCTAssertEqual(result.artifact, artifact)
        XCTAssertEqual(result.errorMessage, "Script timed out after 5 seconds")
    }

    private func makeContext(outputPath: String) -> FileJobContext {
        FileJobContext(
            jobKind: .watchFolder,
            sourceFilePath: "/tmp/in/meeting.wav",
            outputDirectoryPath: URL(fileURLWithPath: outputPath).deletingLastPathComponent().path,
            outputFilePath: outputPath,
            outputFormat: URL(fileURLWithPath: outputPath).pathExtension,
            engineId: "whisperkit",
            engineName: "WhisperKit",
            modelId: "large-v3",
            transcriptText: "Speaker A: Hello",
            detectedLanguage: "en",
            segments: [
                FileJobTranscriptSegment(
                    text: "Hello",
                    start: 0.25,
                    end: 1.5,
                    speakerLabel: "Speaker A",
                    speakerConfidence: 0.91
                )
            ]
        )
    }

    private func makeOutputURL(fileExtension: String = "txt") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanupURLs.append(directory)
        return directory.appendingPathComponent("meeting.\(fileExtension)")
    }
}
