import Foundation
import Combine

@MainActor
final class ModelManagerService: ObservableObject {
    @Published private(set) var modelStatuses: [String: ModelStatus] = [:]
    @Published private(set) var selectedEngine: EngineType
    @Published private(set) var selectedModelId: String?
    @Published private(set) var activeEngine: (any TranscriptionEngine)?

    private let whisperEngine = WhisperEngine()
    private let parakeetEngine = ParakeetEngine()

    private let engineKey = "selectedEngine"
    private let modelKey = "selectedModelId"

    init() {
        let savedEngine = UserDefaults.standard.string(forKey: engineKey)
            .flatMap { EngineType(rawValue: $0) } ?? .whisper
        self.selectedEngine = savedEngine
        self.selectedModelId = UserDefaults.standard.string(forKey: modelKey)

        // Initialize all models as not downloaded
        for model in ModelInfo.allModels {
            modelStatuses[model.id] = .notDownloaded
        }
    }

    var currentEngine: (any TranscriptionEngine)? {
        activeEngine
    }

    func engine(for type: EngineType) -> any TranscriptionEngine {
        switch type {
        case .whisper: whisperEngine
        case .parakeet: parakeetEngine
        }
    }

    func selectEngine(_ engine: EngineType) {
        selectedEngine = engine
        UserDefaults.standard.set(engine.rawValue, forKey: engineKey)
    }

    func selectModel(_ modelId: String) {
        selectedModelId = modelId
        UserDefaults.standard.set(modelId, forKey: modelKey)
    }

    func downloadAndLoadModel(_ model: ModelInfo) async {
        let engine = engine(for: model.engineType)

        modelStatuses[model.id] = .downloading(progress: 0)

        // Listen for phase changes from WhisperKit (loading → prewarming)
        if let whisperEngine = engine as? WhisperEngine {
            whisperEngine.onPhaseChange = { [weak self] phase in
                Task { @MainActor [weak self] in
                    self?.modelStatuses[model.id] = .loading(phase: phase)
                }
            }
        }

        do {
            try await engine.loadModel(model) { [weak self] progress, speed in
                Task { @MainActor [weak self] in
                    if progress >= 0.80 {
                        self?.modelStatuses[model.id] = .loading()
                    } else {
                        self?.modelStatuses[model.id] = .downloading(progress: progress, bytesPerSecond: speed)
                    }
                }
            }

            modelStatuses[model.id] = .ready
            activeEngine = engine
            selectEngine(model.engineType)
            selectModel(model.id)
        } catch {
            modelStatuses[model.id] = .error(error.localizedDescription)
        }
    }

    func loadSelectedModel() async {
        guard let modelId = selectedModelId,
              let model = ModelInfo.allModels.first(where: { $0.id == modelId }) else {
            return
        }

        // Only load if not already loaded
        let engine = engine(for: model.engineType)
        if engine.isModelLoaded {
            activeEngine = engine
            modelStatuses[model.id] = .ready
            return
        }

        await downloadAndLoadModel(model)
    }

    func deleteModel(_ model: ModelInfo) {
        let engine = engine(for: model.engineType)
        engine.unloadModel()
        modelStatuses[model.id] = .notDownloaded

        if selectedModelId == model.id {
            selectedModelId = nil
            UserDefaults.standard.removeObject(forKey: modelKey)
            activeEngine = nil
        }
    }

    func status(for model: ModelInfo) -> ModelStatus {
        modelStatuses[model.id] ?? .notDownloaded
    }

    func resolveEngine(override: EngineType?) -> (any TranscriptionEngine)? {
        if let override {
            let e = engine(for: override)
            return e.isModelLoaded ? e : activeEngine
        }
        return activeEngine
    }

    func transcribe(
        audioSamples: [Float],
        language: String?,
        task: TranscriptionTask,
        engineOverride: EngineType? = nil
    ) async throws -> TranscriptionResult {
        guard let engine = resolveEngine(override: engineOverride) else {
            throw TranscriptionEngineError.modelNotLoaded
        }
        return try await engine.transcribe(
            audioSamples: audioSamples,
            language: language,
            task: task
        )
    }

    func transcribe(
        audioSamples: [Float],
        language: String?,
        task: TranscriptionTask,
        engineOverride: EngineType? = nil,
        onProgress: @escaping (String) -> Bool
    ) async throws -> TranscriptionResult {
        guard let engine = resolveEngine(override: engineOverride) else {
            throw TranscriptionEngineError.modelNotLoaded
        }
        return try await engine.transcribe(
            audioSamples: audioSamples,
            language: language,
            task: task,
            onProgress: onProgress
        )
    }
}
