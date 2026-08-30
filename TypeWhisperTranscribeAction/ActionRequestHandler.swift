import AppKit
import Foundation
import UniformTypeIdentifiers

private final class LoadedFileURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.withLock {
            storage.append(url)
        }
    }

    var values: [URL] {
        lock.withLock { storage }
    }
}

final class ActionRequestHandler: NSObject, NSExtensionRequestHandling {
    private static let serviceName = "Transcribe with TypeWhisper"

    func beginRequest(with context: NSExtensionContext) {
        let inputItems = context.inputItems.compactMap { $0 as? NSExtensionItem }
        let attachments = inputItems.flatMap { $0.attachments ?? [] }

        guard !attachments.isEmpty else {
            cancel(context, message: "No audio or video files were selected.")
            return
        }

        let loadedURLs = LoadedFileURLs()
        let loadingGroup = DispatchGroup()

        for attachment in attachments {
            guard let typeIdentifier = supportedTypeIdentifier(in: attachment) else {
                continue
            }

            loadingGroup.enter()
            attachment.loadInPlaceFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _, _ in
                if let url {
                    loadedURLs.append(url)
                }
                loadingGroup.leave()
            }
        }

        loadingGroup.notify(queue: .main) { [inputItems] in
            let urls = loadedURLs.values
            guard !urls.isEmpty else {
                self.cancel(context, message: "The selected files could not be opened.")
                return
            }

            let pasteboard = NSPasteboard.withUniqueName()
            let pasteboardURLs = urls.map { $0 as NSURL }
            guard pasteboard.writeObjects(pasteboardURLs),
                  NSPerformService(Self.serviceName, pasteboard) else {
                self.cancel(context, message: "TypeWhisper could not receive the selected files.")
                return
            }

            context.completeRequest(returningItems: inputItems, completionHandler: nil)
        }
    }

    private func supportedTypeIdentifier(in provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .audio) || type.conforms(to: .movie)
        }
    }

    private func cancel(_ context: NSExtensionContext, message: String) {
        context.cancelRequest(withError: NSError(
            domain: "com.typewhisper.mac.transcribe-action",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }
}
