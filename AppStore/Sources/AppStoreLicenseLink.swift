#if APPSTORE
import Foundation

/// Connects an existing TypeWhisper (Polar) license to the signed-in account.
///
/// The license key is entered only on a TypeWhisper web page inside
/// `ASWebAuthenticationSession`, never in the app (guideline 3.1.1). The page
/// activates this Mac as one device of the license and returns a one-time code,
/// which the app exchanges with its PKCE verifier for the account entitlement.
/// Guideline 3.1.3(b) allows this because the same Premium features are sold as
/// in-app purchases. Ported from the iOS app (`connectExistingLicense()`).
enum AppStoreLicenseLink {
    static let callbackScheme = "typewhisper"
    static let deviceName = "Mac"

    private static let linkPath = "/premium/polar/link"
    private static let callbackHost = "premium-license"
    private static let callbackPath = "/callback"

    enum Failure: LocalizedError, Equatable {
        case notSignedIn
        case cancelled
        case invalidResponse
        case notConnected

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                AppStoreLicenseLinkCopy.signInFirst
            case .cancelled:
                localizedAppText(
                    "Connecting the license was canceled.",
                    de: "Das Verbinden der Lizenz wurde abgebrochen.",
                    es: "Se canceló la conexión de la licencia."
                )
            case .invalidResponse:
                localizedAppText(
                    "The response of the TypeWhisper license page could not be verified. Please try again.",
                    de: "Die Antwort der TypeWhisper-Lizenzseite konnte nicht überprüft werden. Bitte versuche es erneut.",
                    es: "No se pudo verificar la respuesta de la página de licencias de TypeWhisper. Inténtalo de nuevo."
                )
            case .notConnected:
                localizedAppText(
                    "The existing TypeWhisper license could not be connected.",
                    de: "Die vorhandene TypeWhisper-Lizenz konnte nicht verbunden werden.",
                    es: "No se pudo conectar la licencia de TypeWhisper existente."
                )
            }
        }
    }

    /// The license page must be served by the account service itself, so the
    /// key is never typed into another site.
    static func isValidLinkURL(_ url: URL, accountBaseURL: URL) -> Bool {
        url.scheme == accountBaseURL.scheme
            && url.host == accountBaseURL.host
            && url.port == accountBaseURL.port
            && url.path == linkPath
    }

    /// Reads the one-time code from `typewhisper://premium-license/callback`
    /// after checking that the callback belongs to this link attempt.
    static func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        let values = (URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .reduce(into: [String: String]()) { result, item in
                if result[item.name] == nil, let value = item.value {
                    result[item.name] = value
                }
            }
        guard callbackURL.scheme == callbackScheme,
              callbackURL.host == callbackHost,
              callbackURL.path == callbackPath,
              values["state"] == expectedState else {
            throw Failure.invalidResponse
        }
        guard values["error"] == nil, let code = values["code"], !code.isEmpty else {
            throw Failure.notConnected
        }
        return code
    }
}

/// Wording of the existing-license section. It only talks about connecting a
/// license the customer already has: no prices, checkout links or hints to buy
/// outside the App Store.
enum AppStoreLicenseLinkCopy {
    static var sectionTitle: String {
        localizedAppText("Existing License", de: "Vorhandene Lizenz", es: "Licencia existente")
    }

    static var connectButton: String {
        localizedAppText(
            "Connect Existing TypeWhisper License",
            de: "Vorhandene TypeWhisper-Lizenz verbinden",
            es: "Conectar licencia de TypeWhisper existente"
        )
    }

    static var footer: String {
        localizedAppText(
            "You enter the license key only on a secure TypeWhisper web page, never in the app. This Mac then uses one device slot of the license.",
            de: "Den Lizenzschlüssel gibst du nur auf einer sicheren TypeWhisper-Webseite ein, nie in der App. Dieser Mac belegt danach einen Geräteplatz der Lizenz.",
            es: "Solo introduces la clave de licencia en una página web segura de TypeWhisper, nunca en la app. Después, este Mac ocupa una plaza de dispositivo de la licencia."
        )
    }

    static var signInFirst: String {
        localizedAppText(
            "Sign in with Apple first to connect an existing license.",
            de: "Melde dich zuerst mit Apple an, um eine vorhandene Lizenz zu verbinden.",
            es: "Primero inicia sesión con Apple para conectar una licencia existente."
        )
    }

    static var connected: String {
        localizedAppText(
            "Your TypeWhisper license is connected. Premium is active on this Mac.",
            de: "Deine TypeWhisper-Lizenz ist verbunden. Premium ist auf diesem Mac aktiv.",
            es: "Tu licencia de TypeWhisper está conectada. Premium está activo en este Mac."
        )
    }
}
#endif
