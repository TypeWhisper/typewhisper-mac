import AVFoundation
import Foundation

extension ServiceContainer {
    func makeVoiceTransformCoordinator() -> VoiceTransformCoordinator {
        let recorder = AudioRecordingService(
            recoveryAudioStore: DictationRecoveryAudioStore(
                directory: AppConstants.appSupportDirectory.appendingPathComponent("voice-transform-recovery", isDirectory: true),
                retentionPolicy: .immediately
            )
        )
        let coordinator = VoiceTransformCoordinator(dependencies: .init(
            canStart: { [weak self] in
                guard let self else { return false }
                return dictationViewModel.state == .idle && audioRecorderViewModel.state == .idle
            },
            capture: { [weak self] in
                guard let self else { throw CancellationError() }
                guard !promptProcessingService.fallbackPriorityList.isEmpty else {
                    throw VoiceTransformError.message("Configure an LLM in the global workflow fallback list first.")
                }
                guard modelManagerService.canTranscribe else {
                    throw VoiceTransformError.message("Choose an available speech-to-text model first.")
                }
                return try await textInsertionService.captureVoiceTransformTarget()
            },
            start: { [weak self] in
                guard let self else { throw CancellationError() }
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw VoiceTransformError.message("Allow microphone access in System Settings to speak an instruction.")
                }
                try Task.checkCancellation()
                let input = audioDeviceService.resolvedRecordingInputSelection()
                recorder.microphoneBoostEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.microphoneBoostEnabled)
                recorder.configureInputSelection(
                    deviceID: input.deviceID, hasExplicitDeviceSelection: input.hasExplicitDeviceSelection,
                    usesBluetoothTransport: input.usesBluetoothTransport, deviceName: input.deviceName
                )
                try await recorder.startRecordingAsync()
            },
            stop: { await recorder.stopRecording(policy: .immediate) },
            transcribe: { [weak self] samples in
                guard let self else { throw CancellationError() }
                let result = try await modelManagerService.transcribe(
                    audioSamples: samples, languageSelection: settingsViewModel.languageSelection,
                    task: .transcribe, normalizeNumbers: false
                )
                return result.text
            },
            resolve: { [weak self] instruction in
                guard let self else { throw CancellationError() }
                return try snippetService.resolveTransformInstruction(instruction)
            },
            generate: { [weak self] instruction, source in
                guard let self else { throw CancellationError() }
                return try await promptProcessingService.processVoiceTransform(instruction: instruction, text: source)
            },
            present: { [weak self] in self?.voiceTransformWindow.show() },
            cancellationAvailability: { [weak self] available in
                self?.hotkeyService.isVoiceTransformCancellationAvailable = available
            }
        ))
        dictationViewModel.voiceTransformIsBusy = { [weak coordinator] in coordinator?.isBusy ?? false }
        audioRecorderViewModel.voiceTransformIsBusy = { [weak coordinator] in coordinator?.isBusy ?? false }
        hotkeyService.onVoiceTransformCancel = { [weak coordinator] in coordinator?.cancel() }
        return coordinator
    }
}

extension PromptProcessingService {
    /// Voice transforms inherit the same ordered providers, models, effort, and
    /// temperature preferences as workflows without an explicit override.
    func processVoiceTransform(instruction: String, text: String) async throws -> String {
        try await processWorkflow(
            prompt: VoiceTransformCoordinator.prompt(instruction: instruction), text: text,
            providerOverride: nil, cloudModelOverride: nil,
            temperatureDirective: .inheritProviderSetting, effortOverride: nil
        )
    }
}
