import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Premium settings for phones and tablets that use this Mac over the local
/// network, shown in the Premium window like the other Premium features.
struct RemoteLinkSettingsView: View {
    @ObservedObject private var viewModel = RemoteLinkViewModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PremiumSettingsDetailHeader(
                icon: "iphone.radiowaves.left.and.right",
                accent: .indigo,
                title: PairedDevicesPremiumCopy.title,
                description: localizedAppText(
                    "Paired phones and tablets transcribe and write with this Mac's models and workflows over the local network.",
                    de: "Gekoppelte Smartphones und Tablets transkribieren und schreiben über das lokale Netzwerk mit den Modellen und Workflows dieses Macs.",
                    ja: "ペアリング済みのスマートフォンとタブレットは、ローカルネットワーク経由でこの Mac のモデルとワークフローを使って文字起こしや文章作成を行えます。",
                    zh: "已配对的手机和平板电脑可以通过本地网络使用这台 Mac 的模型和工作流进行转写和写作。",
                    es: "Los teléfonos y tablets vinculados transcriben y escriben con los modelos y flujos de trabajo de este Mac a través de la red local."
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
                                zh: "允许本地网络上的已配对设备"
                            ),
                            info: localizedAppText(
                                "Paired phones and tablets on the same network can send recordings to this Mac and transcribe them with its models. Only paired devices are accepted, and every connection is encrypted. The local API and its token are not exposed.",
                                de: "Gekoppelte Smartphones und Tablets im selben Netzwerk können Aufnahmen an diesen Mac senden und mit seinen Modellen transkribieren lassen. Nur gekoppelte Geräte werden angenommen, und jede Verbindung ist verschlüsselt. Die lokale API und ihr Token bleiben davon unberührt.",
                                ja: "同じネットワーク上のペアリング済みスマートフォンとタブレットは、録音をこの Mac に送信し、この Mac のモデルで文字起こしできます。ペアリング済みのデバイスのみが受け入れられ、すべての接続は暗号化されます。ローカル API とそのトークンは公開されません。",
                                zh: "同一网络上的已配对手机和平板电脑可以将录音发送到这台 Mac，并使用它的模型进行转写。只接受已配对的设备，所有连接均经过加密。本地 API 及其令牌不会被公开。",
                                es: "Los teléfonos y tablets vinculados en la misma red pueden enviar grabaciones a este Mac y transcribirlas con sus modelos. Solo se aceptan dispositivos vinculados y todas las conexiones están cifradas. La API local y su token no quedan expuestos."
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
                                        zh: "如果这台 Mac 一直不可见，请在“隐私与安全性”的“本地网络”中允许 TypeWhisper。"
                                    ),
                                    systemImage: "network.badge.shield.half.filled"
                                )
                                .font(.callout)
                                .foregroundStyle(.orange)
                                Spacer()
                                Button(localizedAppText("Open Settings", de: "Einstellungen öffnen", ja: "設定を開く", zh: "打开设置")) {
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
                                    zh: "允许使用这台 Mac 写作"
                                ),
                                info: localizedAppText(
                                    "Paired devices can run text through this Mac's language models and workflows. Requests may use cloud providers from your language model list, including their API costs.",
                                    de: "Gekoppelte Geräte können Text mit den Sprachmodellen und Workflows dieses Macs verarbeiten. Dabei können Cloud-Anbieter aus deiner Sprachmodell-Liste samt ihrer API-Kosten genutzt werden.",
                                    ja: "ペアリング済みのデバイスは、この Mac の言語モデルとワークフローでテキストを処理できます。言語モデルの一覧にあるクラウドプロバイダが使われ、その API 料金が発生する場合があります。",
                                    zh: "已配对的设备可以使用这台 Mac 的语言模型和工作流处理文本。请求可能会使用你语言模型列表中的云服务提供商，并产生相应的 API 费用。"
                                )
                            )
                        }

                        Button(localizedAppText("Pair Device…", de: "Gerät koppeln …", ja: "デバイスをペアリング…", zh: "配对设备…")) {
                            viewModel.beginPairing()
                        }
                        .disabled(!viewModel.isRunning)
                    }
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(localizedAppText("Paired Devices", de: "Gekoppelte Geräte", ja: "ペアリング済みのデバイス", zh: "已配对的设备"))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    if viewModel.devices.isEmpty {
                        Text(localizedAppText("No paired devices", de: "Keine gekoppelten Geräte", ja: "ペアリング済みのデバイスはありません", zh: "没有已配对的设备"))
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
                es: "Visible como “\(viewModel.computerName)”"
            )
        }
        if viewModel.isRunning {
            return localizedAppText(
                "Waiting for local network access",
                de: "Warte auf Zugriff auf das lokale Netzwerk",
                ja: "ローカルネットワークへのアクセスを待っています",
                zh: "正在等待本地网络访问权限"
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
            Button(localizedAppText("Remove", de: "Entfernen", ja: "削除", zh: "移除"), role: .destructive, action: onRemove)
                .buttonStyle(.borderless)
                .accessibilityLabel(localizedAppText(
                    "Remove \(device.name)",
                    de: "\(device.name) entfernen",
                    ja: "\(device.name) を削除",
                    zh: "移除 \(device.name)",
                    es: "Quitar \(device.name)"
                ))
        }
    }

    private var lastUsedText: String {
        guard let lastSeenAt = device.lastSeenAt else {
            let paired = device.pairedAt.formatted(date: .abbreviated, time: .omitted)
            return localizedAppText("Paired \(paired)", de: "Gekoppelt am \(paired)", ja: "\(paired) にペアリング", zh: "配对于 \(paired)", es: "Vinculado: \(paired)")
        }
        let used = lastSeenAt.formatted(.relative(presentation: .named))
        return localizedAppText("Last used \(used)", de: "Zuletzt verwendet \(used)", ja: "最終使用: \(used)", zh: "上次使用：\(used)", es: "Último uso: \(used)")
    }
}

private struct RemoteLinkPairingSheet: View {
    @ObservedObject var viewModel: RemoteLinkViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text(localizedAppText(
                "Pair a Phone or Tablet",
                de: "Smartphone oder Tablet koppeln",
                ja: "スマートフォンまたはタブレットをペアリング",
                zh: "配对手机或平板电脑",
                es: "Vincular un teléfono o tablet"
            ))
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
        .frame(width: showsQRCode ? 600 : 420)
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

    /// The QR code stays visible while a code request waits, so a device
    /// that only sends requests cannot hide it.
    private var showsQRCode: Bool {
        switch viewModel.pairingState {
        case .closed, .waiting, .confirming: true
        case .finishing, .paired, .failed: false
        }
    }

    static func pairingRequestText(_ request: RemoteLinkPairingRequest) -> String {
        localizedAppText(
            "“\(request.deviceName)” wants to pair with this Mac.",
            de: "„\(request.deviceName)“ möchte sich mit diesem Mac koppeln.",
            ja: "「\(request.deviceName)」がこの Mac とのペアリングを求めています。",
            zh: "“\(request.deviceName)”想要与这台 Mac 配对。",
            es: "“\(request.deviceName)” quiere vincularse con este Mac."
        )
    }

    static func spokenCode(_ code: String) -> String {
        let digits = code.map(String.init).joined(separator: " ")
        return localizedAppText("Code \(digits)", de: "Code \(digits)", ja: "コード \(digits)", zh: "代码 \(digits)", es: "Código \(digits)")
    }

    static func pairedText(_ name: String) -> String {
        localizedAppText("Paired with “\(name)”.", de: "Mit „\(name)“ gekoppelt.", ja: "「\(name)」とペアリングしました。", zh: "已与“\(name)”配对。", es: "Vinculado con “\(name)”.")
    }

    static var failedText: String {
        localizedAppText(
            "Pairing was not completed.",
            de: "Die Kopplung wurde nicht abgeschlossen.",
            ja: "ペアリングは完了しませんでした。",
            zh: "配对未完成。"
        )
    }

    static var scanText: String {
        localizedAppText(
            "In TypeWhisper on your phone or tablet, go to Settings → Mac → Scan QR Code and point the camera at this code.",
            de: "Gehe in TypeWhisper auf deinem Smartphone oder Tablet zu Einstellungen → Mac → QR-Code scannen und richte die Kamera auf diesen Code.",
            ja: "スマートフォンまたはタブレットの TypeWhisper で、設定 → Mac → QR コードをスキャン を開き、カメラをこのコードに向けてください。",
            zh: "在手机或平板电脑上的 TypeWhisper 中，前往“设置”→“Mac”→“扫描二维码”，然后将相机对准此二维码。",
            es: "En TypeWhisper en tu teléfono o tablet, ve a Ajustes → Mac → Escanear código QR y apunta la cámara a este código."
        )
    }

    static func listFallbackText(_ computerName: String) -> String {
        localizedAppText(
            "No QR scanner in TypeWhisper on your device? Choose “\(computerName)” under Settings → Mac there and compare the code.",
            de: "Kein QR-Scanner in TypeWhisper auf deinem Gerät? Wähle dort unter Einstellungen → Mac „\(computerName)“ und vergleiche den Code.",
            ja: "デバイスの TypeWhisper に QR スキャナがない場合は、設定 → Mac で「\(computerName)」を選び、コードを照合してください。",
            zh: "设备上的 TypeWhisper 没有二维码扫描器？请在其“设置”→“Mac”中选择“\(computerName)”，然后核对代码。",
            es: "¿No hay escáner QR en TypeWhisper en tu dispositivo? Elige “\(computerName)” en Ajustes → Mac y compara el código."
        )
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.pairingState {
        case .closed, .waiting, .confirming:
            HStack(alignment: .center, spacing: 20) {
                if let invitation = viewModel.pairingInvitation {
                    RemoteLinkPairingQRCode(payload: invitation.payload)
                } else {
                    ProgressView()
                        .frame(width: RemoteLinkPairingQRCode.maxSide, height: RemoteLinkPairingQRCode.maxSide)
                        .accessibilityLabel(localizedAppText(
                            "Waiting for a device",
                            de: "Warte auf ein Gerät",
                            ja: "デバイスを待っています",
                            zh: "正在等待设备"
                        ))
                }
                VStack(alignment: .leading, spacing: 12) {
                    if case .confirming(let request) = viewModel.pairingState {
                        codeRequest(request)
                    } else {
                        Text(viewModel.pairingInvitation?.name ?? viewModel.computerName)
                            .font(.title3.weight(.semibold))
                        Text(Self.scanText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(Self.listFallbackText(viewModel.computerName))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .finishing:
            VStack(spacing: 12) {
                ProgressView()
                    .accessibilityHidden(true)
                Text(localizedAppText(
                    "Waiting for confirmation on the device…",
                    de: "Warte auf die Bestätigung auf dem Gerät …",
                    ja: "デバイスでの確認を待っています…",
                    zh: "正在等待设备上的确认…"
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

    private func codeRequest(_ request: RemoteLinkPairingRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.pairingRequestText(request))
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.formattedCode(request.code))
                .font(.system(size: 36, weight: .semibold, design: .monospaced))
                .textSelection(.disabled)
                .accessibilityLabel(Self.spokenCode(request.code))
            Text(localizedAppText(
                "Approve only if the device shows the same code.",
                de: "Bestätige nur, wenn das Gerät denselben Code anzeigt.",
                ja: "デバイスに同じコードが表示されている場合のみ承認してください。",
                zh: "仅当设备显示相同的代码时才批准。"
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch viewModel.pairingState {
        case .confirming:
            Button(localizedAppText("Deny", de: "Ablehnen", ja: "拒否", zh: "拒绝")) {
                viewModel.denyPairing()
            }
            Button(localizedAppText("Approve", de: "Bestätigen", ja: "承認", zh: "批准")) {
                viewModel.approvePairing()
            }
            .keyboardShortcut(.defaultAction)
        case .paired:
            // A new QR code with a new secret; the one just used is burnt.
            Button(localizedAppText(
                "Pair Another Device",
                de: "Weiteres Gerät koppeln",
                ja: "別のデバイスをペアリング",
                zh: "配对其他设备",
                es: "Vincular otro dispositivo"
            )) {
                viewModel.beginPairing()
            }
            Button(String(localized: "Done")) {
                viewModel.endPairing()
            }
            .keyboardShortcut(.defaultAction)
        case .failed:
            Button(String(localized: "Cancel")) {
                viewModel.endPairing()
            }
            Button(localizedAppText("Try Again", de: "Erneut versuchen", ja: "再試行", zh: "重试")) {
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

/// The pairing QR code: black modules on white with a quiet zone, scaled in
/// whole points per module without interpolation, so its edges stay sharp,
/// also on a photo of the screen.
private struct RemoteLinkPairingQRCode: View {
    let payload: String

    static let maxSide: CGFloat = 240
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    var body: some View {
        Group {
            if let image = Self.image(for: payload) {
                Image(nsImage: image)
                    .interpolation(.none)
            } else {
                Color.clear
                    .frame(width: Self.maxSide, height: Self.maxSide)
            }
        }
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(localizedAppText(
            "Pairing QR code. Scan it with TypeWhisper on your phone or tablet under Settings → Mac → Scan QR Code.",
            de: "QR-Code zum Koppeln. Scanne ihn mit TypeWhisper auf deinem Smartphone oder Tablet unter Einstellungen → Mac → QR-Code scannen.",
            ja: "ペアリング用 QR コード。スマートフォンまたはタブレットの TypeWhisper で、設定 → Mac → QR コードをスキャン からスキャンしてください。",
            zh: "配对二维码。请在手机或平板电脑上的 TypeWhisper 中，通过“设置”→“Mac”→“扫描二维码”扫描它。",
            es: "Código QR de vinculación. Escanéalo con TypeWhisper en tu teléfono o tablet en Ajustes → Mac → Escanear código QR."
        ))
    }

    static func image(for payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let modules = output.extent.width
        let pointsPerModule = max(1, (maxSide / modules).rounded(.down))
        // Rendered at twice the point size for Retina screens, with nearest
        // sampling, so every module is a block of whole pixels.
        let pixelsPerModule = pointsPerModule * 2
        let scaled = output
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: pixelsPerModule, y: pixelsPerModule))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let side = modules * pointsPerModule
        return NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
    }
}
