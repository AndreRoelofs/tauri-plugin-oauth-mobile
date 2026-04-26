// SPDX-License-Identifier: Apache-2.0

import AppAuth
import AuthenticationServices
import Tauri
import UIKit

/// Tauri 2 mobile plugin that bridges OAuth 2.0 / OIDC flows to AppAuth-iOS.
///
/// AppAuth owns PKCE (S256), `state`/`nonce` validation, discovery, code-for-token
/// exchange, refresh, and end-session. This class is glue: parse the JS payload,
/// dispatch onto the main queue when AppAuth needs the UI, and translate the
/// AppAuth callback shape into Tauri's `Invoke` resolution / rejection model.
///
/// Long-running flows ( `authorize`, `authorizeBrowserOnly`, `endSession` ) hold
/// their session on `self` so the underlying browser process is not deallocated
/// while the user is still interacting with it.
class AppAuthPlugin: Plugin {

    /// Active AppAuth-managed user-agent session for `authorize` / `endSession`.
    /// Retained so AppAuth can drive the browser sheet to completion or cancel.
    private var currentSession: OIDExternalUserAgentSession?

    /// `ASWebAuthenticationSession` used by the bare `authorizeBrowserOnly` flow.
    /// We use ASWeb directly here — there is no PKCE/state/nonce/token-exchange
    /// to drive, so AppAuth's full state machine is not the right primitive.
    private var currentBrowserSession: ASWebAuthenticationSession?

    /// Provider for `ASWebAuthenticationSession`'s presentation anchor on iOS 13+.
    /// Lazily populated when `authorizeBrowserOnly` runs.
    private lazy var browserPresentationContext = BrowserPresentationContext { [weak self] in
        self?.presentationViewController()
    }

    /// Channel registered via `subscribeEvents`. Diagnostic events (browser
    /// opened, redirect intercepted, token-exchange progress) are emitted here.
    private var eventChannel: Channel?

    // MARK: - subscribeEvents

    @objc public func subscribeEvents(_ invoke: Invoke) {
        struct Args: Decodable { let channel: Channel }
        do {
            let args = try invoke.parseArgs(Args.self)
            eventChannel = args.channel
            invoke.resolve()
        } catch {
            invoke.reject("invalid request: \(error.localizedDescription)", code: ErrorMapping.codeInvalidRequest)
        }
    }

    // MARK: - discover

    @objc public func discover(_ invoke: Invoke) {
        let args: DiscoverRequest
        do {
            args = try invoke.parseArgs(DiscoverRequest.self)
        } catch {
            invoke.reject("invalid request: \(error.localizedDescription)", code: ErrorMapping.codeInvalidRequest)
            return
        }
        guard let issuerURL = URL(string: args.issuer) else {
            invoke.reject("invalid issuer URL: \(args.issuer)", code: ErrorMapping.codeInvalidRequest)
            return
        }
        OIDAuthorizationService.discoverConfiguration(forIssuer: issuerURL) { config, error in
            if let error = error {
                ErrorMapping.reject(invoke, error: error)
                return
            }
            guard let config = config else {
                invoke.reject("discovery returned no configuration", code: ErrorMapping.codeServerError)
                return
            }
            invoke.resolve(ServiceConfigurationResponse(from: config))
        }
    }

    // MARK: - authorize

    @objc public func authorize(_ invoke: Invoke) {
        let args: AuthorizeRequest
        do {
            args = try invoke.parseArgs(AuthorizeRequest.self)
        } catch {
            invoke.reject("invalid request: \(error.localizedDescription)", code: ErrorMapping.codeInvalidRequest)
            return
        }
        guard let redirectURL = URL(string: args.redirectUri) else {
            invoke.reject("invalid redirect URI: \(args.redirectUri)", code: ErrorMapping.codeInvalidRequest)
            return
        }

        args.config.resolve { [weak self] config, error in
            guard let self = self else { return }
            if let error = error {
                ErrorMapping.reject(invoke, error: error)
                return
            }
            guard let config = config else {
                invoke.reject("could not resolve service configuration", code: ErrorMapping.codeServerError)
                return
            }
            self.startAuthorize(invoke: invoke, args: args, config: config, redirectURL: redirectURL)
        }
    }

    private func startAuthorize(
        invoke: Invoke,
        args: AuthorizeRequest,
        config: OIDServiceConfiguration,
        redirectURL: URL
    ) {
        let additionalParameters = buildAuthorizationParameters(args)

        // The two-arg `nonce` convenience initializer keeps AppAuth's auto
        // state-generation and PKCE while letting callers opt out of the OIDC
        // nonce (some non-OIDC providers reject it). When `useNonce` is true we
        // let AppAuth generate one for us.
        let request: OIDAuthorizationRequest
        if args.useNonce {
            request = OIDAuthorizationRequest(
                configuration: config,
                clientId: args.clientId,
                scopes: args.scopes.isEmpty ? nil : args.scopes,
                redirectURL: redirectURL,
                responseType: OIDResponseTypeCode,
                additionalParameters: additionalParameters
            )
        } else {
            request = OIDAuthorizationRequest(
                configuration: config,
                clientId: args.clientId,
                scopes: args.scopes.isEmpty ? nil : args.scopes,
                redirectURL: redirectURL,
                responseType: OIDResponseTypeCode,
                nonce: nil,
                additionalParameters: additionalParameters
            )
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let presenter = self.presentationViewController() else {
                invoke.reject("no presenting view controller available", code: ErrorMapping.codeBrowserNotAvailable)
                return
            }
            // Construct the external user agent ourselves rather than going
            // through `OIDAuthState.authState(byPresenting:presenting:prefersEphemeralSession:callback:)`.
            // That convenience method lives in the iOS-specific `OIDAuthState
            // (IOS)` Objective-C category, and Tauri statically links AppAuth
            // into `libapp.a`. The Mach-O linker only pulls `.o` files from a
            // static archive when one of their non-category symbols is
            // referenced, so the category file gets dropped and the selector
            // goes missing at runtime (`NSInvalidArgumentException:
            // unrecognized selector sent to class`). Going through the regular
            // class methods on `OIDExternalUserAgentIOS` and
            // `OIDAuthState.authState(byPresenting:externalUserAgent:callback:)`
            // hits only non-category symbols, which the linker keeps without
            // any `-ObjC` / `-force_load` workarounds in the host app.
            guard let userAgent = OIDExternalUserAgentIOS(
                presenting: presenter,
                prefersEphemeralSession: args.prefersEphemeralSession
            ) else {
                invoke.reject(
                    "could not initialize external user agent",
                    code: ErrorMapping.codeBrowserNotAvailable
                )
                return
            }

            self.emit(.browserOpened)

            self.currentSession = OIDAuthState.authState(
                byPresenting: request,
                externalUserAgent: userAgent
            ) { [weak self] authState, error in
                guard let self = self else { return }
                self.currentSession = nil

                if let error = error {
                    ErrorMapping.reject(invoke, error: error)
                    return
                }
                guard let authState = authState else {
                    invoke.reject(
                        "authorization completed without a state",
                        code: ErrorMapping.codeAuthorizationFailed
                    )
                    return
                }

                self.emit(.tokenExchangeCompleted)
                invoke.resolve(AuthStateResponse(from: authState))
            }
        }
    }

    private func buildAuthorizationParameters(_ args: AuthorizeRequest) -> [String: String] {
        var parameters = args.additionalParameters
        if let prompt = args.prompt {
            parameters["prompt"] = prompt.rawValue
        }
        if let loginHint = args.loginHint {
            parameters["login_hint"] = loginHint
        }
        if let uiLocales = args.uiLocales, !uiLocales.isEmpty {
            parameters["ui_locales"] = uiLocales.joined(separator: " ")
        }
        return parameters
    }

    // MARK: - authorizeBrowserOnly

    @objc public func authorizeBrowserOnly(_ invoke: Invoke) {
        let args: BrowserOnlyRequest
        do {
            args = try invoke.parseArgs(BrowserOnlyRequest.self)
        } catch {
            invoke.reject("invalid request: \(error.localizedDescription)", code: ErrorMapping.codeInvalidRequest)
            return
        }
        guard let authURL = URL(string: args.authUrl) else {
            invoke.reject("invalid auth URL: \(args.authUrl)", code: ErrorMapping.codeInvalidRequest)
            return
        }
        guard let callbackScheme = redirectScheme(for: args.redirectUri) else {
            invoke.reject(
                "redirect URI must be a custom scheme or HTTPS app-link: \(args.redirectUri)",
                code: ErrorMapping.codeInvalidRequest
            )
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Cancel any previous browser session before starting a new one so
            // the system doesn't reject the second call with `.canceledLogin`.
            self.currentBrowserSession?.cancel()

            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                guard let self = self else { return }
                self.currentBrowserSession = nil

                if let error = error {
                    self.handleBrowserOnlyError(invoke: invoke, error: error)
                    return
                }
                guard let callbackURL = callbackURL else {
                    invoke.reject(
                        "browser session ended without a redirect",
                        code: ErrorMapping.codeAuthorizationFailed
                    )
                    return
                }

                self.emit(.redirectIntercepted)
                invoke.resolve(BrowserOnlyResponse(url: callbackURL.absoluteString))
            }

            session.presentationContextProvider = self.browserPresentationContext
            session.prefersEphemeralWebBrowserSession = args.prefersEphemeralSession

            self.currentBrowserSession = session
            if session.start() {
                self.emit(.browserOpened)
            } else {
                self.currentBrowserSession = nil
                invoke.reject(
                    "could not start an authentication session",
                    code: ErrorMapping.codeBrowserNotAvailable
                )
            }
        }
    }

    private func handleBrowserOnlyError(invoke: Invoke, error: Error) {
        let nsError = error as NSError
        if nsError.domain == ASWebAuthenticationSessionErrorDomain
            && nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
        {
            invoke.reject(error.localizedDescription, code: ErrorMapping.codeUserCanceled)
            return
        }
        ErrorMapping.reject(invoke, error: error)
    }

    /// Extract the scheme component of a redirect URI (e.g. `com.example.app:/cb`
    /// → `com.example.app`). HTTPS app-links return `https`, which
    /// `ASWebAuthenticationSession` accepts on iOS 17.4+ for Universal Links.
    private func redirectScheme(for uri: String) -> String? {
        guard let scheme = URLComponents(string: uri)?.scheme, !scheme.isEmpty else {
            return nil
        }
        return scheme
    }

    // MARK: - refresh

    @objc public func refresh(_ invoke: Invoke) {
        let args: RefreshRequest
        do {
            args = try invoke.parseArgs(RefreshRequest.self)
        } catch {
            invoke.reject("invalid request: \(error.localizedDescription)", code: ErrorMapping.codeInvalidRequest)
            return
        }

        args.config.resolve { [weak self] config, error in
            guard let self = self else { return }
            if let error = error {
                ErrorMapping.reject(invoke, error: error)
                return
            }
            guard let config = config else {
                invoke.reject("could not resolve service configuration", code: ErrorMapping.codeServerError)
                return
            }

            let scope = args.scopes.isEmpty ? nil : args.scopes.joined(separator: " ")
            let tokenRequest = OIDTokenRequest(
                configuration: config,
                grantType: OIDGrantTypeRefreshToken,
                authorizationCode: nil,
                redirectURL: nil,
                clientID: args.clientId,
                clientSecret: nil,
                scope: scope,
                refreshToken: args.refreshToken,
                codeVerifier: nil,
                additionalParameters: args.additionalParameters
            )

            self.emit(.tokenExchangeStarted)

            OIDAuthorizationService.perform(tokenRequest) { [weak self] response, error in
                if let error = error {
                    ErrorMapping.reject(invoke, error: error)
                    return
                }
                guard let response = response else {
                    invoke.reject(
                        "token endpoint returned no response",
                        code: ErrorMapping.codeTokenExchangeFailed
                    )
                    return
                }
                self?.emit(.tokenExchangeCompleted)
                invoke.resolve(AuthStateResponse(from: response))
            }
        }
    }

    // MARK: - endSession

    @objc public func endSession(_ invoke: Invoke) {
        let args: EndSessionRequest
        do {
            args = try invoke.parseArgs(EndSessionRequest.self)
        } catch {
            invoke.reject("invalid request: \(error.localizedDescription)", code: ErrorMapping.codeInvalidRequest)
            return
        }
        guard let postLogoutURL = URL(string: args.postLogoutRedirectUri) else {
            invoke.reject(
                "invalid post-logout redirect URI: \(args.postLogoutRedirectUri)",
                code: ErrorMapping.codeInvalidRequest
            )
            return
        }

        args.config.resolve { [weak self] config, error in
            guard let self = self else { return }
            if let error = error {
                ErrorMapping.reject(invoke, error: error)
                return
            }
            guard let config = config else {
                invoke.reject("could not resolve service configuration", code: ErrorMapping.codeServerError)
                return
            }
            self.startEndSession(
                invoke: invoke,
                args: args,
                config: config,
                postLogoutURL: postLogoutURL
            )
        }
    }

    private func startEndSession(
        invoke: Invoke,
        args: EndSessionRequest,
        config: OIDServiceConfiguration,
        postLogoutURL: URL
    ) {
        let request: OIDEndSessionRequest
        if let state = args.state {
            request = OIDEndSessionRequest(
                configuration: config,
                idTokenHint: args.idTokenHint,
                postLogoutRedirectURL: postLogoutURL,
                state: state,
                additionalParameters: args.additionalParameters
            )
        } else {
            request = OIDEndSessionRequest(
                configuration: config,
                idTokenHint: args.idTokenHint,
                postLogoutRedirectURL: postLogoutURL,
                additionalParameters: args.additionalParameters
            )
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let presenter = self.presentationViewController() else {
                invoke.reject("no presenting view controller available", code: ErrorMapping.codeBrowserNotAvailable)
                return
            }
            guard let userAgent = OIDExternalUserAgentIOS(
                presenting: presenter,
                prefersEphemeralSession: args.prefersEphemeralSession
            ) else {
                invoke.reject("could not initialize external user agent", code: ErrorMapping.codeBrowserNotAvailable)
                return
            }

            self.emit(.browserOpened)

            self.currentSession = OIDAuthorizationService.present(
                request,
                externalUserAgent: userAgent
            ) { [weak self] response, error in
                guard let self = self else { return }
                self.currentSession = nil

                if let error = error {
                    ErrorMapping.reject(invoke, error: error)
                    return
                }

                self.emit(.redirectIntercepted)
                // `OIDEndSessionResponse` does not surface the raw redirect URL;
                // mirror the configured post-logout URL so callers can confirm
                // the round-trip without parsing free-form messages.
                invoke.resolve(EndSessionResponseModel(
                    url: postLogoutURL.absoluteString,
                    state: response?.state
                ))
            }
        }
    }

    // MARK: - register (RFC 7591 dynamic client registration)

    @objc public func register(_ invoke: Invoke) {
        let args: RegisterRequest
        do {
            args = try invoke.parseArgs(RegisterRequest.self)
        } catch {
            invoke.reject("invalid request: \(error.localizedDescription)", code: ErrorMapping.codeInvalidRequest)
            return
        }

        let redirectURLs = args.redirectUris.compactMap(URL.init(string:))
        if redirectURLs.count != args.redirectUris.count {
            invoke.reject("one or more redirect URIs are invalid", code: ErrorMapping.codeInvalidRequest)
            return
        }
        if redirectURLs.isEmpty {
            invoke.reject("at least one redirect URI is required", code: ErrorMapping.codeInvalidRequest)
            return
        }

        args.config.resolve { config, error in
            if let error = error {
                ErrorMapping.reject(invoke, error: error)
                return
            }
            guard let config = config else {
                invoke.reject("could not resolve service configuration", code: ErrorMapping.codeServerError)
                return
            }

            // AppAuth-iOS exposes `subjectType` as a single string. The OIDC
            // spec field is plural; we accept the array on the JS side and
            // forward the first value, which matches every provider in the
            // wild that issues distinct types per registration.
            let request = OIDRegistrationRequest(
                configuration: config,
                redirectURIs: redirectURLs,
                responseTypes: args.responseTypes.isEmpty ? nil : args.responseTypes,
                grantTypes: args.grantTypes.isEmpty ? nil : args.grantTypes,
                subjectType: args.subjectTypes.first,
                tokenEndpointAuthMethod: args.tokenEndpointAuthMethod,
                additionalParameters: args.additionalParameters
            )

            OIDAuthorizationService.perform(request) { response, error in
                if let error = error {
                    ErrorMapping.reject(invoke, error: error)
                    return
                }
                guard let response = response else {
                    invoke.reject(
                        "registration endpoint returned no response",
                        code: ErrorMapping.codeInvalidRegistrationResponse
                    )
                    return
                }
                invoke.resolve(RegistrationResponseModel(from: response))
            }
        }
    }

    // MARK: - Internal helpers

    /// Best-effort source for the presentation anchor.
    ///
    /// The Tauri `PluginManager` populates `viewController` when the webview is
    /// created; in the rare case that the anchor is unavailable (background
    /// launches, scene transitions) we fall back to the active key window's
    /// root view controller. iPad multitasking note: the chosen window is the
    /// one currently in the foreground active state, which matches the
    /// expected user-visible session.
    private func presentationViewController() -> UIViewController? {
        if let viewController = manager.viewController {
            return viewController
        }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?
            .rootViewController
    }

    private func emit(_ event: AuthEvent) {
        guard let channel = eventChannel else { return }
        do {
            try channel.send(event)
        } catch {
            // Diagnostic events are best-effort; never let serialization
            // failures break the underlying flow.
        }
    }
}

// MARK: - Diagnostic events

/// Mirrors `crate::events::AuthEvent` (tagged on `kind`, camelCase).
enum AuthEvent: String, Encodable {
    case browserOpened
    case redirectIntercepted
    case tokenExchangeStarted
    case tokenExchangeCompleted

    private enum CodingKeys: String, CodingKey { case kind }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .kind)
    }
}

// MARK: - ASWebAuthenticationSession presentation anchor (iOS 13+)

/// Standalone object so we don't have to make `AppAuthPlugin` an
/// `NSObject`-ASWebAuthenticationPresentationContextProviding hybrid; AppAuth
/// already pulls us into Objective-C territory and stacking another protocol
/// gets noisy.
private final class BrowserPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let resolveAnchor: () -> UIViewController?

    init(resolveAnchor: @escaping () -> UIViewController?) {
        self.resolveAnchor = resolveAnchor
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let window = resolveAnchor()?.view.window {
            return window
        }
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
           let window = scene.windows.first(where: { $0.isKeyWindow })
        {
            return window
        }
        return ASPresentationAnchor()
    }
}

@_cdecl("init_plugin_appauth")
func initPlugin() -> Plugin {
    return AppAuthPlugin()
}
