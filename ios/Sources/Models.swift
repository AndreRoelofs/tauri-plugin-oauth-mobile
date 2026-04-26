// SPDX-License-Identifier: Apache-2.0

import AppAuth
import Foundation

// MARK: - Inputs decoded from JS payloads

struct DiscoverRequest: Decodable {
    let issuer: String
}

/// Mirrors the Rust `ConfigSource` tagged union (`kind: "discovery"|"explicit"`).
enum ConfigSource: Decodable {
    case discovery(issuer: String)
    case explicit(
        authorizationEndpoint: String,
        tokenEndpoint: String,
        endSessionEndpoint: String?,
        registrationEndpoint: String?
    )

    private enum CodingKeys: String, CodingKey {
        case kind
        case issuer
        case authorizationEndpoint
        case tokenEndpoint
        case endSessionEndpoint
        case registrationEndpoint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "discovery":
            self = .discovery(issuer: try container.decode(String.self, forKey: .issuer))
        case "explicit":
            self = .explicit(
                authorizationEndpoint: try container.decode(String.self, forKey: .authorizationEndpoint),
                tokenEndpoint: try container.decode(String.self, forKey: .tokenEndpoint),
                endSessionEndpoint: try container.decodeIfPresent(String.self, forKey: .endSessionEndpoint),
                registrationEndpoint: try container.decodeIfPresent(String.self, forKey: .registrationEndpoint)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "unknown ConfigSource kind: \(kind)"
            )
        }
    }

    /// Resolve to an `OIDServiceConfiguration`, hitting the discovery endpoint
    /// when needed. Completion fires on the main queue.
    func resolve(completion: @escaping (OIDServiceConfiguration?, Error?) -> Void) {
        switch self {
        case .discovery(let issuer):
            guard let issuerURL = URL(string: issuer) else {
                DispatchQueue.main.async {
                    completion(nil, AppAuthBridgeError.invalidRequest("invalid issuer URL: \(issuer)"))
                }
                return
            }
            OIDAuthorizationService.discoverConfiguration(forIssuer: issuerURL) { config, error in
                completion(config, error)
            }
        case .explicit(let authEndpoint, let tokenEndpoint, let endSessionEndpoint, let registrationEndpoint):
            guard
                let authURL = URL(string: authEndpoint),
                let tokenURL = URL(string: tokenEndpoint)
            else {
                DispatchQueue.main.async {
                    completion(nil, AppAuthBridgeError.invalidRequest("invalid endpoint URL"))
                }
                return
            }
            let config = OIDServiceConfiguration(
                authorizationEndpoint: authURL,
                tokenEndpoint: tokenURL,
                issuer: nil,
                registrationEndpoint: registrationEndpoint.flatMap(URL.init(string:)),
                endSessionEndpoint: endSessionEndpoint.flatMap(URL.init(string:))
            )
            DispatchQueue.main.async { completion(config, nil) }
        }
    }
}

/// OIDC `prompt` parameter values. `snake_case` to match the Rust enum.
enum Prompt: String, Decodable {
    case login
    case consent
    case selectAccount = "select_account"
    case none
}

struct AuthorizeRequest: Decodable {
    let config: ConfigSource
    let clientId: String
    let redirectUri: String
    let scopes: [String]
    let additionalParameters: [String: String]
    let prompt: Prompt?
    let loginHint: String?
    let uiLocales: [String]?
    let prefersEphemeralSession: Bool
    let useNonce: Bool

    private enum CodingKeys: String, CodingKey {
        case config, clientId, redirectUri, scopes, additionalParameters
        case prompt, loginHint, uiLocales, prefersEphemeralSession, useNonce
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        config = try c.decode(ConfigSource.self, forKey: .config)
        clientId = try c.decode(String.self, forKey: .clientId)
        redirectUri = try c.decode(String.self, forKey: .redirectUri)
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
        additionalParameters = try c.decodeIfPresent([String: String].self, forKey: .additionalParameters) ?? [:]
        prompt = try c.decodeIfPresent(Prompt.self, forKey: .prompt)
        loginHint = try c.decodeIfPresent(String.self, forKey: .loginHint)
        uiLocales = try c.decodeIfPresent([String].self, forKey: .uiLocales)
        prefersEphemeralSession = try c.decodeIfPresent(Bool.self, forKey: .prefersEphemeralSession) ?? true
        useNonce = try c.decodeIfPresent(Bool.self, forKey: .useNonce) ?? true
    }
}

struct BrowserOnlyRequest: Decodable {
    let authUrl: String
    let redirectUri: String
    let prefersEphemeralSession: Bool

    private enum CodingKeys: String, CodingKey {
        case authUrl, redirectUri, prefersEphemeralSession
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        authUrl = try c.decode(String.self, forKey: .authUrl)
        redirectUri = try c.decode(String.self, forKey: .redirectUri)
        prefersEphemeralSession = try c.decodeIfPresent(Bool.self, forKey: .prefersEphemeralSession) ?? true
    }
}

struct RefreshRequest: Decodable {
    let config: ConfigSource
    let clientId: String
    let refreshToken: String
    let scopes: [String]
    let additionalParameters: [String: String]

    private enum CodingKeys: String, CodingKey {
        case config, clientId, refreshToken, scopes, additionalParameters
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        config = try c.decode(ConfigSource.self, forKey: .config)
        clientId = try c.decode(String.self, forKey: .clientId)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
        additionalParameters = try c.decodeIfPresent([String: String].self, forKey: .additionalParameters) ?? [:]
    }
}

struct RegisterRequest: Decodable {
    let config: ConfigSource
    let redirectUris: [String]
    let clientName: String?
    let responseTypes: [String]
    let grantTypes: [String]
    let subjectTypes: [String]
    let tokenEndpointAuthMethod: String?
    let additionalParameters: [String: String]

    private enum CodingKeys: String, CodingKey {
        case config, redirectUris, clientName, responseTypes, grantTypes
        case subjectTypes, tokenEndpointAuthMethod, additionalParameters
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        config = try c.decode(ConfigSource.self, forKey: .config)
        redirectUris = try c.decode([String].self, forKey: .redirectUris)
        clientName = try c.decodeIfPresent(String.self, forKey: .clientName)
        responseTypes = try c.decodeIfPresent([String].self, forKey: .responseTypes) ?? []
        grantTypes = try c.decodeIfPresent([String].self, forKey: .grantTypes) ?? []
        subjectTypes = try c.decodeIfPresent([String].self, forKey: .subjectTypes) ?? []
        tokenEndpointAuthMethod = try c.decodeIfPresent(String.self, forKey: .tokenEndpointAuthMethod)
        additionalParameters = try c.decodeIfPresent([String: String].self, forKey: .additionalParameters) ?? [:]
    }
}

struct EndSessionRequest: Decodable {
    let config: ConfigSource
    let idTokenHint: String
    let postLogoutRedirectUri: String
    let state: String?
    let additionalParameters: [String: String]
    let prefersEphemeralSession: Bool

    private enum CodingKeys: String, CodingKey {
        case config, idTokenHint, postLogoutRedirectUri, state
        case additionalParameters, prefersEphemeralSession
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        config = try c.decode(ConfigSource.self, forKey: .config)
        idTokenHint = try c.decode(String.self, forKey: .idTokenHint)
        postLogoutRedirectUri = try c.decode(String.self, forKey: .postLogoutRedirectUri)
        state = try c.decodeIfPresent(String.self, forKey: .state)
        additionalParameters = try c.decodeIfPresent([String: String].self, forKey: .additionalParameters) ?? [:]
        prefersEphemeralSession = try c.decodeIfPresent(Bool.self, forKey: .prefersEphemeralSession) ?? true
    }
}

// MARK: - Outputs encoded to JS responses

struct ServiceConfigurationResponse: Encodable {
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let endSessionEndpoint: String?
    let registrationEndpoint: String?
    let issuer: String?
    let additionalParameters: [String: String]

    init(from config: OIDServiceConfiguration) {
        authorizationEndpoint = config.authorizationEndpoint.absoluteString
        tokenEndpoint = config.tokenEndpoint.absoluteString
        endSessionEndpoint = config.endSessionEndpoint?.absoluteString
        registrationEndpoint = config.registrationEndpoint?.absoluteString
        issuer = config.issuer?.absoluteString
        // Surface the raw discovery doc fields beyond the typed five so callers
        // can pick up provider-specific extensions (e.g. `userinfo_endpoint`).
        // Stringify nested arrays / objects to keep the wire shape uniform; the
        // typed fields above remain the primary source of truth.
        if let discovery = config.discoveryDocument {
            additionalParameters = stringifyAnyDictionary(discovery.discoveryDictionary)
        } else {
            additionalParameters = [:]
        }
    }
}

struct AuthStateResponse: Encodable {
    let accessToken: String?
    let accessTokenExpiresAt: Int64?
    let idToken: String?
    let refreshToken: String?
    let scope: String?
    let tokenType: String?
    let authorizationCode: String?
    let additionalParameters: [String: String]

    /// Construct from the merged `OIDAuthState` produced by the full
    /// `authorize` flow. Token-endpoint values take precedence over the
    /// authorization-endpoint snapshots they replaced.
    init(from authState: OIDAuthState) {
        let tokenResponse = authState.lastTokenResponse
        let authResponse = authState.lastAuthorizationResponse
        accessToken = tokenResponse?.accessToken ?? authResponse.accessToken
        accessTokenExpiresAt = (tokenResponse?.accessTokenExpirationDate
            ?? authResponse.accessTokenExpirationDate)
            .map { Int64($0.timeIntervalSince1970) }
        idToken = tokenResponse?.idToken ?? authResponse.idToken
        refreshToken = authState.refreshToken
        scope = authState.scope ?? tokenResponse?.scope ?? authResponse.scope
        tokenType = tokenResponse?.tokenType ?? authResponse.tokenType
        authorizationCode = authResponse.authorizationCode
        additionalParameters = stringifyDictionary(tokenResponse?.additionalParameters)
    }

    /// Construct from a bare `OIDTokenResponse` (e.g. refresh flows where there
    /// is no preceding authorization response).
    init(from tokenResponse: OIDTokenResponse) {
        accessToken = tokenResponse.accessToken
        accessTokenExpiresAt = tokenResponse.accessTokenExpirationDate.map { Int64($0.timeIntervalSince1970) }
        idToken = tokenResponse.idToken
        refreshToken = tokenResponse.refreshToken ?? tokenResponse.request.refreshToken
        scope = tokenResponse.scope
        tokenType = tokenResponse.tokenType
        authorizationCode = nil
        additionalParameters = stringifyDictionary(tokenResponse.additionalParameters)
    }
}

struct BrowserOnlyResponse: Encodable {
    let url: String
}

struct RegistrationResponseModel: Encodable {
    let clientId: String
    let clientIdIssuedAt: Int64?
    let clientSecret: String?
    let clientSecretExpiresAt: Int64?
    let registrationAccessToken: String?
    let registrationClientUri: String?
    let tokenEndpointAuthMethod: String?
    let additionalParameters: [String: String]

    init(from response: OIDRegistrationResponse) {
        clientId = response.clientID
        clientIdIssuedAt = response.clientIDIssuedAt.map { Int64($0.timeIntervalSince1970) }
        clientSecret = response.clientSecret
        clientSecretExpiresAt = response.clientSecretExpiresAt.map { Int64($0.timeIntervalSince1970) }
        registrationAccessToken = response.registrationAccessToken
        registrationClientUri = response.registrationClientURI?.absoluteString
        tokenEndpointAuthMethod = response.tokenEndpointAuthenticationMethod
        additionalParameters = stringifyDictionary(response.additionalParameters)
    }
}

struct EndSessionResponseModel: Encodable {
    let url: String
    let state: String?
}

// MARK: - Internal helpers

/// Errors raised by the Swift bridge before reaching AppAuth (e.g. malformed
/// inputs). Carries the same shape as AppAuth `NSError`s so the unified error
/// mapper can handle them.
enum AppAuthBridgeError: LocalizedError {
    case invalidRequest(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): return message
        }
    }
}

/// Coerce AppAuth's additional-parameter dictionaries to a JSON-encodable
/// `[String: String]`. AppAuth surfaces both `[String: NSObject<NSCopying>]`
/// (token / registration responses) and `[String: Any]`
/// (`OIDServiceDiscovery.discoveryDictionary`) — handling `Any` covers both.
/// OAuth/OIDC additional parameters are strings or numbers in practice;
/// nested arrays / objects are JSON-serialized so values stay round-trippable.
func stringifyDictionary(_ source: [String: Any]?) -> [String: String] {
    guard let source = source else { return [:] }
    var out: [String: String] = [:]
    out.reserveCapacity(source.count)
    for (key, value) in source {
        out[key] = stringify(value)
    }
    return out
}

func stringifyAnyDictionary(_ source: [String: Any]) -> [String: String] {
    return stringifyDictionary(source)
}

private func stringify(_ value: Any) -> String {
    if let s = value as? String { return s }
    if let n = value as? NSNumber { return n.stringValue }
    if JSONSerialization.isValidJSONObject(value),
       let data = try? JSONSerialization.data(withJSONObject: value),
       let s = String(data: data, encoding: .utf8)
    {
        return s
    }
    return String(describing: value)
}
