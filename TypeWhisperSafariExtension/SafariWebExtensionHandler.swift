import Foundation
import SafariServices

/// Answers the TypeWhisper web extension in Safari. Its only request, `connection`, returns
/// the API port and token of the TypeWhisper app that contains this extension. The reply is
/// empty while that app's API server is off, and the extension then uses its stored settings.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]

        var reply: [String: Any] = [:]
        if message?["type"] as? String == "connection",
           let connection = Self.currentConnection() {
            reply = ["port": connection.port, "token": connection.token]
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    private static func currentConnection() -> SafariExtensionConnection? {
        guard let extensionIdentifier = Bundle.main.bundleIdentifier,
              let hostIdentifier = SafariExtensionConnection.hostBundleIdentifier(ofExtension: extensionIdentifier),
              let container = SafariExtensionConnection.containerURL() else {
            return nil
        }
        return SafariExtensionConnection.load(
            from: SafariExtensionConnection.fileURL(hostBundleIdentifier: hostIdentifier, in: container)
        )
    }
}
