// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import Tauri
import UIKit

struct AuthenticateOptions: Decodable {
    let authUrl: String
    let callbackScheme: String
    var prefersEphemeralSession: Bool?
}

class OAuthSessionPlugin: Plugin, ASWebAuthenticationPresentationContextProviding {
    /// ASWebAuthenticationSession is deallocated mid-flight if the caller
    /// doesn't retain it, which silently breaks the flow. Hold the active
    /// session for the duration of the auth attempt.
    private var activeSession: ASWebAuthenticationSession?

    @objc public func authenticate(_ invoke: Invoke) throws {
        let args = try invoke.parseArgs(AuthenticateOptions.self)

        guard let url = URL(string: args.authUrl) else {
            invoke.reject("invalid auth URL", code: "INVALID_AUTH_URL")
            return
        }

        let scheme = args.callbackScheme
        guard !scheme.isEmpty, !scheme.contains(":"), !scheme.contains("/") else {
            invoke.reject("invalid callback scheme", code: "INVALID_CALLBACK_SCHEME")
            return
        }

        let prefersEphemeral = args.prefersEphemeralSession ?? true

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                invoke.reject("plugin deallocated", code: "SESSION_FAILED")
                return
            }

            // Refuse to start a new session while one is already running:
            // the system would silently dismiss the old one and the original
            // caller would never resolve.
            if self.activeSession != nil {
                invoke.reject("an authentication session is already in progress", code: "SESSION_BUSY")
                return
            }

            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: scheme
            ) { [weak self] callbackURL, error in
                self?.activeSession = nil

                if let error = error {
                    let nsError = error as NSError
                    if nsError.domain == ASWebAuthenticationSessionErrorDomain,
                       let code = ASWebAuthenticationSessionError.Code(rawValue: nsError.code) {
                        switch code {
                        case .canceledLogin:
                            invoke.reject("user canceled the authentication session", code: "USER_CANCELED")
                            return
                        case .presentationContextNotProvided, .presentationContextInvalid:
                            invoke.reject(
                                "the platform could not present the authentication session",
                                code: "PRESENTATION_FAILED"
                            )
                            return
                        @unknown default:
                            break
                        }
                    }
                    invoke.reject(error.localizedDescription, code: "SESSION_FAILED")
                    return
                }

                guard let callbackURL = callbackURL else {
                    invoke.reject("the authentication session returned no callback URL", code: "SESSION_FAILED")
                    return
                }

                invoke.resolve(["url": callbackURL.absoluteString])
            }

            session.prefersEphemeralWebBrowserSession = prefersEphemeral
            session.presentationContextProvider = self
            self.activeSession = session

            if !session.start() {
                self.activeSession = nil
                invoke.reject(
                    "the platform could not present the authentication session",
                    code: "PRESENTATION_FAILED"
                )
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Anchor the sheet to the active webview's window so it lays out
        // correctly under split view / iPad multitasking.
        if let window = self.manager.viewController?.view.window {
            return window
        }
        return UIApplication.shared
            .connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow) }
            .first ?? ASPresentationAnchor()
    }
}

@_cdecl("init_plugin_oauth_session")
func initPlugin() -> Plugin {
    return OAuthSessionPlugin()
}
