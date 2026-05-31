import Foundation
import SherpaOnnxC

final class SenseVoiceONNXRecognizer: SenseVoiceRecognizing, @unchecked Sendable {
    private let recognizer: OpaquePointer
    private let inferenceLock = NSLock()

    init(modelDirectory: URL, language: String) throws {
        let modelPath = modelDirectory.appendingPathComponent("model.int8.onnx").path
        let tokensPath = modelDirectory.appendingPathComponent("tokens.txt").path
        guard FileManager.default.fileExists(atPath: modelPath),
              FileManager.default.fileExists(atPath: tokensPath) else {
            throw SenseVoicePluginError.incompleteModelAssets
        }

        var createdRecognizer: OpaquePointer?
        modelPath.withCString { modelCString in
            tokensPath.withCString { tokensCString in
                language.withCString { languageCString in
                    "cpu".withCString { providerCString in
                        "greedy_search".withCString { decodingCString in
                            var config = SherpaOnnxOfflineRecognizerConfig()
                            config.feat_config.sample_rate = 16_000
                            config.feat_config.feature_dim = 80
                            config.model_config.tokens = tokensCString
                            config.model_config.num_threads = 4
                            config.model_config.provider = providerCString
                            config.model_config.sense_voice.model = modelCString
                            config.model_config.sense_voice.language = languageCString
                            config.model_config.sense_voice.use_itn = 1
                            config.decoding_method = decodingCString
                            createdRecognizer = SherpaOnnxCreateOfflineRecognizer(&config)
                        }
                    }
                }
            }
        }

        guard let createdRecognizer else {
            throw SenseVoicePluginError.runtimeUnavailable
        }
        self.recognizer = createdRecognizer
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }

    func transcribe(samples: [Float], sampleRate: Int) throws -> String {
        inferenceLock.lock()
        defer { inferenceLock.unlock() }

        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
            throw SenseVoicePluginError.transcriptionFailed("Failed to create offline stream.")
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxAcceptWaveformOffline(
                stream,
                Int32(sampleRate),
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }

        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
            throw SenseVoicePluginError.transcriptionFailed("Failed to read recognizer result.")
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }

        guard let text = result.pointee.text else {
            return ""
        }
        return String(cString: text)
    }
}
