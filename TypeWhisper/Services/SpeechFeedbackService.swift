import Foundation
import AppKit
import Combine
import os
import TypeWhisperPluginSDK

private final class PendingTTSPlaybackSession: TTSPlaybackSession, @unchecked Sendable {
    private struct State {
        var isActive = true
        var onFinish: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isActive: Bool {
        state.withLock { $0.isActive }
    }

    var onFinish: (@Sendable () -> Void)? {
        get { state.withLock { $0.onFinish } }
        set {
            let shouldNotify = state.withLock { state in
                state.onFinish = newValue
                return !state.isActive
            }
            if shouldNotify {
                newValue?()
            }
        }
    }

    func stop() {
        let callback: (@Sendable () -> Void)? = state.withLock { state in
            guard state.isActive else { return nil }
            state.isActive = false
            return state.onFinish
        }
        callback?()
    }
}

@MainActor
final class SpeechFeedbackService: ObservableObject {
    private let defaults: UserDefaults
    private let providerResolver: @MainActor () -> [any TTSProviderPlugin]
    private let isVoiceOverEnabled: @MainActor () -> Bool

    private var playbackSession: (any TTSPlaybackSession)?
    private var speakTask: Task<Void, Never>?

    @Published var spokenFeedbackEnabled: Bool {
        didSet {
            defaults.set(spokenFeedbackEnabled, forKey: UserDefaultsKeys.spokenFeedbackEnabled)
        }
    }

    @Published var selectedProviderId: String {
        didSet {
            defaults.set(selectedProviderId, forKey: UserDefaultsKeys.spokenFeedbackProviderId)
        }
    }

    var isSpeaking: Bool {
        playbackSession?.isActive ?? false
    }

    var availableProviders: [(id: String, displayName: String)] {
        providerResolver().map { ($0.providerId, $0.providerDisplayName) }
    }

    var hasAvailableProviders: Bool {
        !providerResolver().isEmpty
    }

    var effectiveProviderId: String? {
        selectedProvider?.providerId
    }

    var selectedProviderDisplayName: String? {
        selectedProvider?.providerDisplayName
    }

    var currentSettingsSummary: String? {
        selectedProvider?.settingsSummary
    }

    init(
        defaults: UserDefaults = .standard,
        providerResolver: @escaping @MainActor () -> [any TTSProviderPlugin] = { PluginManager.shared.ttsProviders },
        isVoiceOverEnabled: @escaping @MainActor () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }
    ) {
        self.defaults = defaults
        self.providerResolver = providerResolver
        self.isVoiceOverEnabled = isVoiceOverEnabled
        self.spokenFeedbackEnabled = defaults.bool(forKey: UserDefaultsKeys.spokenFeedbackEnabled)
        self.selectedProviderId = defaults.string(forKey: UserDefaultsKeys.spokenFeedbackProviderId) ?? ""
    }

    func speakAutomaticTranscription(text: String, language: String?) {
        guard spokenFeedbackEnabled else { return }
        guard !isVoiceOverEnabled() else { return }
        guard !text.isEmpty else { return }
        speak(TTSSpeakRequest(text: text, language: language, purpose: .transcription))
    }

    func readBack(text: String, language: String?) {
        if isSpeaking {
            stopSpeaking()
            return
        }
        speak(TTSSpeakRequest(text: text, language: language, purpose: .manualReadback))
    }

    func stopSpeaking() {
        speakTask?.cancel()
        speakTask = nil
        playbackSession?.stop()
        playbackSession = nil
    }

    @discardableResult
    func disableIfNoProvidersAvailable() -> Bool {
        guard !hasAvailableProviders, spokenFeedbackEnabled else { return false }
        spokenFeedbackEnabled = false
        return true
    }

    private var selectedProvider: TTSProviderPlugin? {
        let providers = providerResolver()
        if let exact = providers.first(where: { $0.providerId == selectedProviderId }) {
            return exact
        }
        if let configured = providers.first(where: { $0.isConfigured }) {
            return configured
        }
        return providers.first
    }

    private func speak(_ request: TTSSpeakRequest) {
        stopSpeaking()
        guard let provider = selectedProvider else { return }
        let pendingSession = PendingTTSPlaybackSession()
        let pendingSessionID = ObjectIdentifier(pendingSession as AnyObject)
        setPlaybackSession(pendingSession)

        speakTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let session = try await provider.speak(request)
                if Task.isCancelled {
                    session.stop()
                    return
                }
                self.setPlaybackSession(session)
            } catch {
                if let activeSession = self.playbackSession,
                   ObjectIdentifier(activeSession as AnyObject) == pendingSessionID {
                    self.playbackSession = nil
                }
            }
            self.speakTask = nil
        }
    }

    private func setPlaybackSession(_ session: any TTSPlaybackSession) {
        let sessionID = ObjectIdentifier(session as AnyObject)
        session.onFinish = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if let activeSession = self.playbackSession,
                   ObjectIdentifier(activeSession as AnyObject) == sessionID {
                    self.playbackSession = nil
                }
            }
        }
        playbackSession = session
    }
}
