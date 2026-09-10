import AppKit
import AVFoundation
import CoreImage
import SwiftUI

struct IOSCompanionPromoView: View {
    let appStoreURL: URL
    let onOpenAppStore: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasEntered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.05, blue: 0.08),
                    Color(red: 0.03, green: 0.10, blue: 0.17),
                    .black,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HStack(spacing: 34) {
                promoVideo

                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(localizedAppText(
                            "TypeWhisper is now on iPhone and iPad",
                            de: "TypeWhisper gibt es jetzt für iPhone und iPad"
                        ))
                        .font(.title2.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                        Text(localizedAppText(
                            "Take private voice-to-text with you — including the voice keyboard and Apple Watch companion.",
                            de: "Nimm privates Voice-to-Text mit – inklusive Diktier-Tastatur und Apple-Watch-App."
                        ))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(alignment: .center, spacing: 18) {
                        QRCodeImageView(url: appStoreURL)
                            .frame(width: 142, height: 142)

                        VStack(alignment: .leading, spacing: 9) {
                            promoFeature("keyboard", localizedAppText(
                                "Dictate in any app",
                                de: "In jeder App diktieren"
                            ))
                            promoFeature("lock.shield.fill", localizedAppText(
                                "On-device models",
                                de: "Lokale Modelle"
                            ))
                            promoFeature("applewatch", localizedAppText(
                                "Apple Watch included",
                                de: "Apple Watch inklusive"
                            ))
                        }
                    }

                    Text(localizedAppText(
                        "Scan the QR code with your iPhone or open the App Store page on this Mac.",
                        de: "Scanne den QR-Code mit deinem iPhone oder öffne die App-Store-Seite auf diesem Mac."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Button(localizedAppText("Close", de: "Schließen"), action: onDismiss)
                            .buttonStyle(.bordered)
                            .keyboardShortcut(.cancelAction)

                        Button(action: onOpenAppStore) {
                            Label(
                                localizedAppText("Open App Store", de: "App Store öffnen"),
                                systemImage: "arrow.up.right.square"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .frame(width: 330, alignment: .leading)
            }
            .padding(30)
            .opacity(hasEntered ? 1 : 0)
            .offset(y: hasEntered || reduceMotion ? 0 : 12)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(9)
                    .background(.black.opacity(0.24), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(18)
            .accessibilityLabel(localizedAppText("Close", de: "Schließen"))
        }
        .frame(width: 690, height: 486)
        .preferredColorScheme(.dark)
        .task {
            guard !hasEntered else { return }
            if reduceMotion {
                hasEntered = true
                return
            }

            try? await Task.sleep(for: .milliseconds(70))
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                hasEntered = true
            }
        }
    }

    @ViewBuilder
    private var promoVideo: some View {
        if let url = Bundle.main.url(forResource: "ios-companion-promo", withExtension: "mp4") {
            LoopingPromoVideoView(url: url, isPlaying: hasEntered && !reduceMotion)
                .frame(width: 218, height: 388)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.13), lineWidth: 1)
                }
                .shadow(color: .blue.opacity(0.28), radius: 24)
                .accessibilityHidden(true)
        } else {
            WaveformLogoView(isActive: hasEntered && !reduceMotion)
                .frame(width: 110, height: 110)
                .frame(width: 218, height: 388)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 24))
                .accessibilityLabel(Text("TypeWhisper"))
        }
    }

    private func promoFeature(_ systemImage: String, _ title: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
    }
}

private struct QRCodeImageView: View {
    let url: URL

    var body: some View {
        Group {
            if let image = QRCodeRenderer.image(for: url.absoluteString) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
            } else {
                Image(systemName: "qrcode")
                    .resizable()
                    .scaledToFit()
                    .padding(22)
                    .foregroundStyle(.black)
            }
        }
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel(localizedAppText(
            "QR code for TypeWhisper in the App Store",
            de: "QR-Code für TypeWhisper im App Store"
        ))
    }
}

private enum QRCodeRenderer {
    static func image(for string: String) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

private struct LoopingPromoVideoView: NSViewRepresentable {
    let url: URL
    let isPlaying: Bool

    func makeNSView(context: Context) -> LoopingPromoVideoNSView {
        LoopingPromoVideoNSView(url: url, isPlaying: isPlaying)
    }

    func updateNSView(_ nsView: LoopingPromoVideoNSView, context: Context) {
        nsView.setPlaying(isPlaying)
    }

    static func dismantleNSView(_ nsView: LoopingPromoVideoNSView, coordinator: ()) {
        nsView.stop()
    }
}

private final class LoopingPromoVideoNSView: NSView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init(url: URL, isPlaying: Bool) {
        super.init(frame: .zero)
        wantsLayer = true

        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none

        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        setPlaying(isPlaying)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func makeBackingLayer() -> CALayer {
        AVPlayerLayer()
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func setPlaying(_ shouldPlay: Bool) {
        if shouldPlay {
            player.play()
        } else {
            player.pause()
            player.seek(to: .zero)
        }
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }

    private var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}
