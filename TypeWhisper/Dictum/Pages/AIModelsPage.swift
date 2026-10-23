import SwiftUI
import TypeWhisperPluginSDK

struct AIModelsPage: View {
    @ObservedObject private var plugins = PluginManager.shared
    @ObservedObject private var processing = ServiceContainer.shared.promptProcessingService
    @State private var selection: UUID?
    @State private var key = ""
    @State private var hasStoredKey = false
    @State private var endpoint = ""
    @State private var customModel = ""
    @State private var modelsKnown = true
    @State private var showEndpoint = false
    @State private var testing = false
    @State private var hoveredProvider: UUID?
    @State private var testResult: ConnectionResult?
    @FocusState private var keyFocused: Bool

    enum ConnectionResult { case connected(Double), failed(String) }
    private var selected: LLMFallbackPriorityItem? {
        processing.fallbackPriorityList.first { $0.id == selection } ?? processing.fallbackPriorityList.first
    }

    var body: some View {
        DictumPageFrame(page: .aiModels, actions: {
            Menu {
                ForEach(ProviderConfiguration.choices) { choice in
                    Button { add(choice) } label: {
                        if configuredItem(choice) != nil { Label(choice.name, systemImage: "checkmark") }
                        else { Text(verbatim: choice.name) }
                    }
                }
            } label: { Label { Text("Add", tableName: "DictumStyle") } icon: { Image(systemName: "plus") } }
                .menuIndicator(.hidden).buttonStyle(DictumControlStyle(kind: .smallButton)).fixedSize()
        }) {
            if processing.fallbackPriorityList.isEmpty { emptyState }
            else {
                HStack(alignment: .top, spacing: 20) {
                    providerList.frame(width: 276)
                    if let item = selected { detail(item).id(item.id) }
                }.padding(.horizontal, 28).padding(.top, 4).padding(.bottom, 28)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }.font(DictumTheme.Typography.body)
            .onChange(of: selected?.id, initial: true) { _, _ in loadSelection() }
            .onChange(of: processing.modelsForProvider(selected?.providerId ?? "").map(\.id)) { _, _ in
                if let id = selected?.providerId, id.hasPrefix("openai-compatible"),
                   let snapshot = try? ProviderConfiguration.configure(["id": id]) {
                    modelsKnown = snapshot["modelsKnown"] as? Bool ?? false
                }
            }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles").font(.system(size: 24)).foregroundStyle(.secondary)
                .frame(width: 52, height: 52).background(DictumTheme.card, in: RoundedRectangle(cornerRadius: 14))
            Text("Connect an AI model", tableName: "DictumStyle").font(.headline)
            Text("provider.empty", tableName: "DictumStyle").foregroundStyle(.secondary).multilineTextAlignment(.center)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                ForEach(ProviderConfiguration.choices) { choice in
                    Button { add(choice) } label: {
                        HStack(spacing: 9) {
                            tile(choice.name, size: 22)
                            Text(verbatim: choice.name).font(.system(size: 12))
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.plain).background(DictumTheme.card, in: RoundedRectangle(cornerRadius: 10))
                }
            }.padding(.top, 10)
        }.frame(maxWidth: 520).padding(.top, 70).padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 12) {
            List {
                ForEach(Array(processing.fallbackPriorityList.enumerated()), id: \.element.id) { index, item in
                    Button { selection = item.id } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(.tertiary)
                            .opacity(hoveredProvider == item.id ? 1 : 0)
                        Text(verbatim: "\(index + 1)").foregroundStyle(.secondary).frame(width: 14)
                        tile(name(item), size: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: name(item)).lineLimit(1)
                            Text(verbatim: item.modelId ?? processing.defaultModelId(for: item.providerId) ?? "")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Circle().fill(processing.failedFallbackIDs.contains(item.id) ? DictumTheme.danger :
                                        processing.isProviderReady(item.providerId) ? DictumTheme.success : DictumTheme.warning)
                            .frame(width: 7, height: 7)
                    }.padding(.vertical, 6).padding(.horizontal, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                        .listRowSeparator(.hidden)
                        .listRowBackground(RoundedRectangle(cornerRadius: 9).fill(selected?.id == item.id ? DictumTheme.accentSoft : .clear))
                        .onHover { hoveredProvider = $0 ? item.id : nil }
                }.onMove { processing.moveLLMFallbacks(from: $0, to: $1) }
            }.listStyle(.plain).scrollContentBackground(.hidden)
                .frame(height: min(420, CGFloat(processing.fallbackPriorityList.count) * 50 + 8))
                .background(DictumTheme.card, in: RoundedRectangle(cornerRadius: 12))
            Text("provider.order", tableName: "DictumStyle").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func detail(_ item: LLMFallbackPriorityItem) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                tile(name(item), size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: name(item)).font(.headline)
                    let index = processing.fallbackPriorityList.firstIndex { $0.id == item.id } ?? 0
                    if index == 0 { Text("Primary", tableName: "DictumStyle").foregroundStyle(.secondary) }
                    else { Text("Backup \(index)", tableName: "DictumStyle").foregroundStyle(.secondary) }
                }
                Spacer()
                Menu {
                    Button {
                        if let index = processing.fallbackPriorityList.firstIndex(where: { $0.id == item.id }) {
                            processing.moveLLMFallbacks(from: IndexSet(integer: index), to: 0)
                        }
                    } label: { Text("Make Primary", tableName: "DictumStyle") }
                    if item.providerId.hasPrefix("openai-compatible") {
                        Button { showEndpoint = true } label: { Text("Custom Endpoint…", tableName: "DictumStyle") }
                    }
                    Divider()
                    Button(role: .destructive) { remove(item) } label: { Text("Remove", tableName: "DictumStyle") }
                } label: { Image(systemName: "ellipsis") }
                    .menuIndicator(.hidden).buttonStyle(.borderless).tint(DictumTheme.textSecondary).fixedSize()
            }
            if item.providerId.hasPrefix("openai-compatible"), showEndpoint {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Endpoint", tableName: "DictumStyle")
                    TextField("https://api.example.com/v1", text: $endpoint).onSubmit { saveEndpoint(item) }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("API key", tableName: "DictumStyle").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack {
                    SecureField(hasStoredKey ? "••••••••••••" : "", text: $key).focused($keyFocused)
                        .accessibilityLabel(Text("API key", tableName: "DictumStyle")).onSubmit { saveKey(item) }
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(processing.failedFallbackIDs.contains(item.id) ? DictumTheme.danger : .clear))
                    Button {
                        if let pasted = NSPasteboard.general.string(forType: .string) { key = pasted; saveKey(item) }
                    } label: { Text("Paste", tableName: "DictumStyle") }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            modelPicker(item)
            Divider()
            HStack {
                if testing {
                    ProgressView().controlSize(.small)
                    Text("Testing…", tableName: "DictumStyle")
                } else if let testResult {
                    switch testResult {
                    case .connected(let seconds):
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(DictumTheme.success)
                        Text("Connected · \(seconds.formatted(.number.precision(.fractionLength(1)))) s response", tableName: "DictumStyle")
                            .foregroundStyle(DictumTheme.success)
                    case .failed(let message):
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DictumTheme.danger)
                        Text(LocalizedStringKey(message), tableName: "DictumStyle").foregroundStyle(DictumTheme.danger)
                    }
                }
                Spacer(minLength: 4)
                Button { test(item) } label: { Text("Test Connection", tableName: "DictumStyle") }
                    .buttonStyle(DictumControlStyle(kind: .smallButton)).disabled(testing)
            }.font(.system(size: 12))
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(DictumTheme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func modelPicker(_ item: LLMFallbackPriorityItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model", tableName: "DictumStyle").font(.system(size: 12)).foregroundStyle(.secondary)
            let models = processing.modelsForProvider(item.providerId)
            if models.isEmpty || !modelsKnown {
                TextField("", text: $customModel).onSubmit { saveModel(item, model: customModel) }
                    .accessibilityLabel(Text("Model", tableName: "DictumStyle"))
            } else {
                let current = item.modelId ?? processing.defaultModelId(for: item.providerId) ?? models.first?.id ?? ""
                Picker(selection: Binding(get: { current }, set: { saveModel(item, model: $0) })) {
                    if !models.contains(where: { $0.id == current }) { Text(verbatim: current).tag(current) }
                    ForEach(models, id: \.id) { Text(verbatim: $0.displayName).tag($0.id) }
                } label: { Text("Model", tableName: "DictumStyle") }
                    .pickerStyle(.menu).labelsHidden().buttonStyle(.borderless).tint(.primary)
                    .font(.system(size: 13)).padding(.leading, 10).padding(.trailing, 9)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 6).fill(DictumTheme.control)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DictumTheme.controlBorder, lineWidth: 0.5))
                            .shadow(color: DictumTheme.controlShadow, radius: 1.5, y: 1)
                    }
                    .overlay(alignment: .trailing) {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold)).foregroundStyle(DictumTheme.textPrimary.opacity(0.55))
                            .frame(width: 20, height: 14, alignment: .trailing)
                            .background(DictumTheme.control).padding(.trailing, 6)
                            .accessibilityHidden(true).allowsHitTesting(false)
                    }
            }
        }
    }

    private func tile(_ name: String, size: CGFloat) -> some View {
        Text(verbatim: String(name.prefix(1))).font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white).frame(width: size, height: size)
            .background(tileColor(name), in: RoundedRectangle(cornerRadius: 7))
    }
    private func tileColor(_ name: String) -> Color {
        let colors: [String: Color] = ["DeepSeek": Color(red: 0.30, green: 0.42, blue: 1),
            "Anthropic": Color(red: 0.85, green: 0.47, blue: 0.34), "Groq": .orange,
            "Gemini": .blue, "通义千问": .purple, "Qwen": .purple, "智谱": .blue, "Zhipu": .blue,
            "硅基流动": .purple, "SiliconFlow": .purple, "OpenRouter": .gray]
        return colors[name] ?? Color(white: 0.1)
    }
    private func name(_ item: LLMFallbackPriorityItem) -> String {
        plugins.llmProvider(for: item.providerId).map(ProviderConfiguration.displayName) ?? item.providerId
    }
    private func add(_ choice: ProviderConfiguration.Choice) {
        if let existing = configuredItem(choice) { selection = existing.id; return }
        do {
            var providerID = choice.id
            var model: String?
            if choice.preset {
                let result = try ProviderConfiguration.configure(["preset": choice.id])
                guard let id = result["id"] as? String else { return }
                providerID = id
                model = result["model"] as? String
            }
            processing.addLLMFallback(providerId: providerID, modelId: model)
            selection = processing.fallbackPriorityList.last { $0.providerId == providerID }?.id
            keyFocused = true
        } catch { testResult = .failed("provider.configurationError") }
    }
    private func remove(_ item: LLMFallbackPriorityItem) {
        processing.removeLLMFallback(item)
        ProviderConfiguration.removeProfile(item.providerId)
    }
    private func configuredItem(_ choice: ProviderConfiguration.Choice) -> LLMFallbackPriorityItem? {
        guard choice.id != "custom" else { return nil }
        return processing.fallbackPriorityList.first { $0.providerId == choice.id || name($0) == choice.name }
    }
    private func loadSelection() {
        selection = selected?.id
        key = ""
        hasStoredKey = selected.map { processing.isProviderReady($0.providerId) } ?? false
        testResult = nil
        endpoint = ""
        customModel = selected?.modelId ?? ""
        modelsKnown = true
        showEndpoint = false
        if let item = selected, item.providerId.hasPrefix("openai-compatible"),
           let snapshot = try? ProviderConfiguration.configure(["id": item.providerId]) {
            endpoint = snapshot["url"] as? String ?? ""
            customModel = item.modelId ?? snapshot["model"] as? String ?? ""
            modelsKnown = snapshot["modelsKnown"] as? Bool ?? false
            hasStoredKey = snapshot["hasKey"] as? Bool ?? false
            showEndpoint = (snapshot["name"] as? String)?.hasPrefix("OpenAI Compatible") == true
        }
    }
    @discardableResult private func saveKey(_ item: LLMFallbackPriorityItem) -> Bool {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        do {
            try ProviderConfiguration.saveKey(key, providerID: item.providerId)
            key = ""
            hasStoredKey = true
            testResult = nil
            return true
        } catch { testResult = .failed("provider.configurationError"); return false }
    }
    @discardableResult private func saveEndpoint(_ item: LLMFallbackPriorityItem) -> Bool {
        do { _ = try ProviderConfiguration.configure(["id": item.providerId, "url": endpoint]); return true }
        catch { testResult = .failed("provider.configurationError"); return false }
    }
    private func saveModel(_ item: LLMFallbackPriorityItem, model: String) {
        processing.updateLLMFallback(item, providerId: item.providerId, modelId: model)
    }
    private func test(_ original: LLMFallbackPriorityItem) {
        var item = original
        guard saveKey(item) else { return }
        if item.providerId.hasPrefix("openai-compatible"), !saveEndpoint(item) { return }
        if !modelsKnown, !customModel.isEmpty {
            saveModel(item, model: customModel)
            item.modelId = customModel
        }
        testing = true
        testResult = nil
        Task { @MainActor in
            let start = Date()
            do {
                _ = try await processing.processWorkflow(prompt: "Return only OK.", text: "Connection test",
                    providerOverride: item.providerId, cloudModelOverride: item.modelId, temperatureDirective: .providerDefault)
                processing.recordConnectionResult(for: item, succeeded: true)
                if selected?.id == item.id { testResult = .connected(Date().timeIntervalSince(start)) }
                ProviderConfiguration.refreshModels(item.providerId)
            } catch {
                processing.recordConnectionResult(for: item, succeeded: false)
                let message = ProviderConfiguration.connectionErrorKey(error)
                if selected?.id == item.id { testResult = .failed(message) }
            }
            testing = false
        }
    }
}
