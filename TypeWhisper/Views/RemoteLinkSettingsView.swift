import SwiftUI

/// Premium settings for iPhones and iPads that use this Mac over the local
/// network, shown in the Premium window like the other Premium features.
struct RemoteLinkSettingsView: View {
    @ObservedObject private var viewModel = RemoteLinkViewModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PremiumSettingsDetailHeader(
                icon: "iphone.radiowaves.left.and.right",
                accent: .indigo,
                title: localizedAppText("iPhone and iPad", de: "iPhone und iPad", ja: "iPhone と iPad", zh: "iPhone 和 iPad", zhHant: "iPhone 和 iPad"),
                description: localizedAppText(
                    "Paired iPhones and iPads transcribe and write with this Mac's models and workflows over the local network.",
                    de: "Gekoppelte iPhones und iPads transkribieren und schreiben über das lokale Netzwerk mit den Modellen und Workflows dieses Macs.",
                    ja: "ペアリング済みの iPhone と iPad は、ローカルネットワーク経由でこの Mac のモデルとワークフローを使って文字起こしや文章作成を行えます。",
                    zh: "已配对的 iPhone 和 iPad 可以通过本地网络使用这台 Mac 的模型和工作流进行转写和写作。",
                    zhHant: "已配對的 iPhone 和 iPad 可以透過本機網路使用這台 Mac 的模型和工作流程進行轉錄和寫作。"
                ),
                status: viewModel.isEnabled ? statusText : String(localized: "premium.hub.status.off"),
                statusColor: viewModel.isEnabled && viewModel.isAdvertised ? .green : .secondary
            )

            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: Binding(get: { viewModel.isEnabled }, set: { viewModel.setEnabled($0) })) {
                        SettingsInfoLabel(
                            title: localizedAppText(
                                "Allow Paired Devices on the Local Network",
                                de: "Gekoppelte Geräte im lokalen Netzwerk erlauben",
                                ja: "ローカルネットワーク上のペアリング済みデバイスを許可",
                                zh: "允许本地网络上的已配对设备",
                                zhHant: "允許本機網路上的已配對裝置"
                            ),
                            info: localizedAppText(
                                "Paired iPhones and iPads on the same network can send recordings to this Mac and transcribe them with its models. Only paired devices are accepted, and every connection is encrypted. The local API and its token are not exposed.",
                                de: "Gekoppelte iPhones und iPads im selben Netzwerk können Aufnahmen an diesen Mac senden und mit seinen Modellen transkribieren lassen. Nur gekoppelte Geräte werden angenommen, und jede Verbindung ist verschlüsselt. Die lokale API und ihr Token bleiben davon unberührt.",
                                ja: "同じネットワーク上のペアリング済み iPhone と iPad は、録音をこの Mac に送信し、この Mac のモデルで文字起こしできます。ペアリング済みのデバイスのみが受け入れられ、すべての接続は暗号化されます。ローカル API とそのトークンは公開されません。",
                                zh: "同一网络上的已配对 iPhone 和 iPad 可以将录音发送到这台 Mac，并使用它的模型进行转写。只接受已配对的设备，所有连接均经过加密。本地 API 及其令牌不会被公开。",
                                zhHant: "同一網路上的已配對 iPhone 和 iPad 可以將錄音傳送到這台 Mac，並使用它的模型進行轉錄。只接受已配對的裝置，所有連線均經過加密。本機 API 及其權杖不會被公開。"
                            )
                        )
                    }

                    if viewModel.isEnabled {
                        HStack {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(viewModel.isAdvertised ? .green : .orange)
                                .font(.caption2)
                                .accessibilityHidden(true)
                            Text(statusText)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        if viewModel.isRunning && !viewModel.isAdvertised {
                            HStack(alignment: .firstTextBaseline) {
                                Label(
                                    localizedAppText(
                                        "If this Mac stays invisible, allow TypeWhisper under Local Network in Privacy & Security.",
                                        de: "Bleibt dieser Mac unsichtbar, erlaube TypeWhisper unter „Lokales Netzwerk“ in „Datenschutz & Sicherheit“.",
                                        ja: "この Mac が表示されないままの場合は、「プライバシーとセキュリティ」の「ローカルネットワーク」で TypeWhisper を許可してください。",
                                        zh: "如果这台 Mac 一直不可见，请在“隐私与安全性”的“本地网络”中允许 TypeWhisper。",
                                        zhHant: "如果這台 Mac 一直不可見，請在「隱私權與安全性」的「本機網路」中允許 TypeWhisper。"
                                    ),
                                    systemImage: "network.badge.shield.half.filled"
                                )
                                .font(.callout)
                                .foregroundStyle(.orange)
                                Spacer()
                                Button(localizedAppText("Open Settings", de: "Einstellungen öffnen", ja: "設定を開く", zh: "打开设置", zhHant: "開啟設定")) {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                        }

                        if let error = viewModel.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.callout)
                        }

                        Toggle(isOn: $viewModel.isWritingAllowed) {
                            SettingsInfoLabel(
                                title: localizedAppText(
                                    "Allow Writing with This Mac",
                                    de: "Schreiben mit diesem Mac erlauben",
                                    ja: "この Mac での文章作成を許可",
                                    zh: "允许使用这台 Mac 写作",
                                    zhHant: "允許使用這台 Mac 寫作"
                                ),
                                info: localizedAppText(
                                    "Paired devices can run text through this Mac's language models and workflows. Requests may use cloud providers from your language model list, including their API costs.",
                                    de: "Gekoppelte Geräte können Text mit den Sprachmodellen und Workflows dieses Macs verarbeiten. Dabei können Cloud-Anbieter aus deiner Sprachmodell-Liste samt ihrer API-Kosten genutzt werden.",
                                    ja: "ペアリング済みのデバイスは、この Mac の言語モデルとワークフローでテキストを処理できます。言語モデルの一覧にあるクラウドプロバイダが使われ、その API 料金が発生する場合があります。",
                                    zh: "已配对的设备可以使用这台 Mac 的语言模型和工作流处理文本。请求可能会使用你语言模型列表中的云服务提供商，并产生相应的 API 费用。",
                                    zhHant: "已配對的裝置可以使用這台 Mac 的語言模型和工作流程處理文字。請求可能會使用你語言模型清單中的雲端服務供應商，並產生相應的 API 費用。"
                                )
                            )
                        }

                        Button(localizedAppText("Pair Device…", de: "Gerät koppeln …", ja: "デバイスをペアリング…", zh: "配对设备…", zhHant: "配對裝置…")) {
                            viewModel.beginPairing()
                        }
                        .disabled(!viewModel.isRunning)
                    }
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(localizedAppText("Paired Devices", de: "Gekoppelte Geräte", ja: "ペアリング済みのデバイス", zh: "已配对的设备", zhHant: "已配對的裝置"))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    if viewModel.devices.isEmpty {
                        Text(localizedAppText("No paired devices", de: "Keine gekoppelten Geräte", ja: "ペアリング済みのデバイスはありません", zh: "没有已配对的设备", zhHant: "沒有已配對的裝置"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.devices) { device in
                            RemoteLinkDeviceRow(device: device) {
                                viewModel.removeDevice(device)
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            ServiceContainer.shared.accessibilityAnnouncementService.announceError(message)
        }
        .sheet(isPresented: Binding(
            get: { viewModel.pairingState != .closed },
            set: { if !$0 { viewModel.endPairing() } }
        )) {
            RemoteLinkPairingSheet(viewModel: viewModel)
        }
    }
}

private extension RemoteLinkSettingsView {
    var statusText: String {
        if viewModel.isAdvertised {
            return localizedAppText(
                "Visible as “\(viewModel.computerName)”",
                de: "Sichtbar als „\(viewModel.computerName)“",
                ja: "「\(viewModel.computerName)」として表示中",
                zh: "显示为“\(viewModel.computerName)”",
                zhHant: "顯示為「\(viewModel.computerName)」",
                es: "Visible como “\(viewModel.computerName)”"
            )
        }
        if viewModel.isRunning {
            return localizedAppText(
                "Waiting for local network access",
                de: "Warte auf Zugriff auf das lokale Netzwerk",
                ja: "ローカルネットワークへのアクセスを待っています",
                zh: "正在等待本地网络访问权限",
                zhHant: "正在等待本機網路存取權限"
            )
        }
        return String(localized: "Not running")
    }
}

private struct RemoteLinkDeviceRow: View {
    let device: RemoteLinkDevice
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "iphone")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                Text(lastUsedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button(localizedAppText("Remove", de: "Entfernen", ja: "削除", zh: "移除", zhHant: "移除"), role: .destructive, action: onRemove)
                .buttonStyle(.borderless)
                .accessibilityLabel(localizedAppText(
                    "Remove \(device.name)",
                    de: "\(device.name) entfernen",
                    ja: "\(device.name) を削除",
                    zh: "移除 \(device.name)",
                    zhHant: "移除 \(device.name)",
                    es: "Quitar \(device.name)"
                ))
        }
    }

    private var lastUsedText: String {
        guard let lastSeenAt = device.lastSeenAt else {
            let paired = device.pairedAt.formatted(date: .abbreviated, time: .omitted)
            return localizedAppText("Paired \(paired)", de: "Gekoppelt am \(paired)", ja: "\(paired) にペアリング", zh: "配对于 \(paired)", zhHant: "配對於 \(paired)", es: "Vinculado: \(paired)")
        }
        let used = lastSeenAt.formatted(.relative(presentation: .named))
        return localizedAppText("Last used \(used)", de: "Zuletzt verwendet \(used)", ja: "最終使用: \(used)", zh: "上次使用：\(used)", zhHant: "上次使用：\(used)", es: "Último uso: \(used)")
    }
}

private struct RemoteLinkPairingSheet: View {
    @ObservedObject var viewModel: RemoteLinkViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text(localizedAppText("Pair iPhone or iPad", de: "iPhone oder iPad koppeln", ja: "iPhone または iPad をペアリング", zh: "配对 iPhone 或 iPad", zhHant: "配對 iPhone 或 iPad"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            content
                .frame(maxWidth: .infinity)
                .frame(minHeight: 140)

            HStack {
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 420)
        // The pairing request arrives from the other device, so VoiceOver
        // users hear it, including the code to compare, and the outcome.
        .onChange(of: viewModel.pairingState) { _, state in
            switch state {
            case .confirming(let request):
                announce(Self.pairingRequestText(request) + " " + Self.spokenCode(request.code))
            case .paired(let name):
                announce(Self.pairedText(name))
            case .failed:
                announce(Self.failedText)
            case .closed, .waiting, .finishing:
                break
            }
        }
    }

    private func announce(_ message: String) {
        ServiceContainer.shared.accessibilityAnnouncementService.announce(message)
    }

    static func pairingRequestText(_ request: RemoteLinkPairingRequest) -> String {
        localizedAppText(
            "“\(request.deviceName)” wants to pair with this Mac.",
            de: "„\(request.deviceName)“ möchte sich mit diesem Mac koppeln.",
            ja: "「\(request.deviceName)」がこの Mac とのペアリングを求めています。",
            zh: "“\(request.deviceName)”想要与这台 Mac 配对。",
            zhHant: "「\(request.deviceName)」想要與這台 Mac 配對。",
            es: "“\(request.deviceName)” quiere vincularse con este Mac."
        )
    }

    static func spokenCode(_ code: String) -> String {
        let digits = code.map(String.init).joined(separator: " ")
        return localizedAppText("Code \(digits)", de: "Code \(digits)", ja: "コード \(digits)", zh: "代码 \(digits)", zhHant: "程式碼 \(digits)", es: "Código \(digits)")
    }

    static func pairedText(_ name: String) -> String {
        localizedAppText("Paired with “\(name)”.", de: "Mit „\(name)“ gekoppelt.", ja: "「\(name)」とペアリングしました。", zh: "已与“\(name)”配对。", zhHant: "已與「\(name)」配對。", es: "Vinculado con “\(name)”.")
    }

    static var failedText: String {
        localizedAppText(
            "Pairing was not completed.",
            de: "Die Kopplung wurde nicht abgeschlossen.",
            ja: "ペアリングは完了しませんでした。",
            zh: "配对未完成。",
            zhHant: "配對未完成。"
        )
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.pairingState {
        case .closed, .waiting:
            VStack(spacing: 12) {
                ProgressView()
                    .accessibilityLabel(localizedAppText(
                        "Waiting for a device",
                        de: "Warte auf ein Gerät",
                        ja: "デバイスを待っています",
                        zh: "正在等待设备",
                        zhHant: "正在等待裝置"
                    ))
                Text(localizedAppText(
                    "On your iPhone or iPad, open TypeWhisper, go to Settings → Mac and choose “\(viewModel.computerName)”.",
                    de: "Öffne TypeWhisper auf deinem iPhone oder iPad, gehe zu Einstellungen → Mac und wähle „\(viewModel.computerName)“.",
                    ja: "iPhone または iPad で TypeWhisper を開き、設定 → Mac で「\(viewModel.computerName)」を選択してください。",
                    zh: "在 iPhone 或 iPad 上打开 TypeWhisper，前往“设置”→“Mac”，然后选择“\(viewModel.computerName)”。",
                    zhHant: "在 iPhone 或 iPad 上開啟 TypeWhisper，前往「設定」→「Mac」，然後選擇「\(viewModel.computerName)」。",
                    es: "En tu iPhone o iPad, abre TypeWhisper, ve a Ajustes → Mac y elige “\(viewModel.computerName)”."
                ))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
        case .confirming(let request):
            VStack(spacing: 12) {
                Text(Self.pairingRequestText(request))
                    .multilineTextAlignment(.center)
                Text(Self.formattedCode(request.code))
                    .font(.system(size: 36, weight: .semibold, design: .monospaced))
                    .textSelection(.disabled)
                    .accessibilityLabel(Self.spokenCode(request.code))
                Text(localizedAppText(
                    "Approve only if the device shows the same code.",
                    de: "Bestätige nur, wenn das Gerät denselben Code anzeigt.",
                    ja: "デバイスに同じコードが表示されている場合のみ承認してください。",
                    zh: "仅当设备显示相同的代码时才批准。",
                    zhHant: "僅當裝置顯示相同的程式碼時才批准。"
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        case .finishing:
            VStack(spacing: 12) {
                ProgressView()
                    .accessibilityHidden(true)
                Text(localizedAppText(
                    "Waiting for confirmation on the device…",
                    de: "Warte auf die Bestätigung auf dem Gerät …",
                    ja: "デバイスでの確認を待っています…",
                    zh: "正在等待设备上的确认…",
                    zhHant: "正在等待裝置上的確認…"
                ))
            }
        case .paired(let name):
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(Self.pairedText(name))
            }
        case .failed:
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(Self.failedText)
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch viewModel.pairingState {
        case .confirming:
            Button(localizedAppText("Deny", de: "Ablehnen", ja: "拒否", zh: "拒绝", zhHant: "拒絕")) {
                viewModel.denyPairing()
            }
            Button(localizedAppText("Approve", de: "Bestätigen", ja: "承認", zh: "批准", zhHant: "批准")) {
                viewModel.approvePairing()
            }
            .keyboardShortcut(.defaultAction)
        case .paired:
            Button(String(localized: "Done")) {
                viewModel.endPairing()
            }
            .keyboardShortcut(.defaultAction)
        case .failed:
            Button(String(localized: "Cancel")) {
                viewModel.endPairing()
            }
            Button(localizedAppText("Try Again", de: "Erneut versuchen", ja: "再試行", zh: "重试", zhHant: "重試")) {
                viewModel.beginPairing()
            }
            .keyboardShortcut(.defaultAction)
        case .closed, .waiting, .finishing:
            Button(String(localized: "Cancel")) {
                viewModel.endPairing()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    static func formattedCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}
