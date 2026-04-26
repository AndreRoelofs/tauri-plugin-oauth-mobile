// SPDX-License-Identifier: Apache-2.0

package app.tauri.appauth

import android.app.Activity
import android.net.Uri
import androidx.activity.result.ActivityResult
import app.tauri.annotation.ActivityCallback
import app.tauri.annotation.Command
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Channel
import app.tauri.plugin.Invoke
import app.tauri.plugin.Plugin
import net.openid.appauth.AuthorizationException
import net.openid.appauth.AuthorizationRequest
import net.openid.appauth.AuthorizationResponse
import net.openid.appauth.AuthorizationService
import net.openid.appauth.AuthorizationServiceConfiguration
import net.openid.appauth.EndSessionRequest
import net.openid.appauth.EndSessionResponse
import net.openid.appauth.GrantTypeValues
import net.openid.appauth.RegistrationRequest
import net.openid.appauth.RegistrationResponse
import net.openid.appauth.ResponseTypeValues
import net.openid.appauth.TokenRequest
import net.openid.appauth.TokenResponse

/// Tauri 2 mobile plugin that bridges OAuth 2.0 / OIDC flows to AppAuth-Android.
///
/// AppAuth owns PKCE (S256), `state`/`nonce` validation, discovery, code-for-token
/// exchange, refresh, and end-session. This class is glue: parse the JS payload,
/// hand off to AppAuth, and translate AppAuth's callback / `Intent` shape into
/// Tauri's `Invoke` resolution / rejection model.
///
/// `AuthorizationService` is created lazily and disposed in `onDestroy` so the
/// Custom Tabs binding is released on activity teardown. We re-create it on the
/// next command if needed (the plugin instance can outlive the service).
@TauriPlugin
class AppAuthPlugin(private val activity: Activity) : Plugin(activity) {

    private var authService: AuthorizationService? = null
    private var eventChannel: Channel? = null

    override fun onDestroy() {
        authService?.dispose()
        authService = null
        super.onDestroy()
    }

    private fun authService(): AuthorizationService {
        return authService ?: AuthorizationService(activity).also { authService = it }
    }

    // MARK: - subscribeEvents

    @Command
    fun subscribeEvents(invoke: Invoke) {
        try {
            val args = invoke.parseArgs(SubscribeEventsArgs::class.java)
            eventChannel = args.channel
            invoke.resolve()
        } catch (e: Exception) {
            invoke.reject("invalid request: ${e.message}", ErrorMapping.CODE_INVALID_REQUEST, e)
        }
    }

    // MARK: - discover

    @Command
    fun discover(invoke: Invoke) {
        val args = try {
            invoke.parseArgs(DiscoverArgs::class.java)
        } catch (e: Exception) {
            invoke.reject("invalid request: ${e.message}", ErrorMapping.CODE_INVALID_REQUEST, e)
            return
        }
        val issuerUri = Uri.parse(args.issuer)
        AuthorizationServiceConfiguration.fetchFromIssuer(issuerUri) { config, ex ->
            if (ex != null) {
                ErrorMapping.reject(invoke, ex)
                return@fetchFromIssuer
            }
            if (config == null) {
                invoke.reject(
                    "discovery returned no configuration",
                    ErrorMapping.CODE_SERVER_ERROR
                )
                return@fetchFromIssuer
            }
            invoke.resolveObject(serviceConfigurationResponse(config))
        }
    }

    // MARK: - authorize

    @Command
    fun authorize(invoke: Invoke) {
        val args = try {
            invoke.parseArgs(AuthorizeArgs::class.java)
        } catch (e: Exception) {
            invoke.reject("invalid request: ${e.message}", ErrorMapping.CODE_INVALID_REQUEST, e)
            return
        }
        val redirectUri = parseUri(args.redirectUri) ?: run {
            invoke.reject(
                "invalid redirect URI: ${args.redirectUri}",
                ErrorMapping.CODE_INVALID_REQUEST
            )
            return
        }

        resolveServiceConfiguration(invoke, args.config) { config ->
            startAuthorize(invoke, args, config, redirectUri)
        }
    }

    private fun startAuthorize(
        invoke: Invoke,
        args: AuthorizeArgs,
        config: AuthorizationServiceConfiguration,
        redirectUri: Uri
    ) {
        val builder = AuthorizationRequest.Builder(
            config,
            args.clientId,
            ResponseTypeValues.CODE,
            redirectUri
        )
        if (args.scopes.isNotEmpty()) {
            builder.setScopes(args.scopes)
        }
        if (args.additionalParameters.isNotEmpty()) {
            builder.setAdditionalParameters(args.additionalParameters)
        }
        args.prompt?.let { builder.setPrompt(it.value) }
        args.loginHint?.let { builder.setLoginHint(it) }
        args.uiLocales?.takeIf { it.isNotEmpty() }?.let {
            builder.setUiLocales(it.joinToString(" "))
        }
        if (!args.useNonce) {
            // Builder's default generates a fresh nonce; explicit `null` opts
            // out for non-OIDC providers that reject the parameter.
            builder.setNonce(null)
        }

        val intent = try {
            authService().getAuthorizationRequestIntent(builder.build())
        } catch (e: android.content.ActivityNotFoundException) {
            invoke.reject(
                "no compatible browser is available",
                ErrorMapping.CODE_BROWSER_NOT_AVAILABLE,
                e
            )
            return
        }

        emit(AuthEvent.BrowserOpened)
        startActivityForResult(invoke, intent, "handleAuthorizeResult")
    }

    @ActivityCallback
    fun handleAuthorizeResult(invoke: Invoke, result: ActivityResult) {
        val data = result.data
        val response = data?.let { AuthorizationResponse.fromIntent(it) }
        val exception = data?.let { AuthorizationException.fromIntent(it) }

        if (exception != null) {
            ErrorMapping.reject(invoke, exception)
            return
        }
        if (response == null) {
            invoke.reject(
                "authorization completed without a response",
                ErrorMapping.CODE_AUTHORIZATION_FAILED
            )
            return
        }

        emit(AuthEvent.RedirectIntercepted)
        emit(AuthEvent.TokenExchangeStarted)

        val tokenRequest = response.createTokenExchangeRequest()
        authService().performTokenRequest(tokenRequest) { tokenResponse, tokenEx ->
            if (tokenEx != null) {
                ErrorMapping.reject(invoke, tokenEx)
                return@performTokenRequest
            }
            if (tokenResponse == null) {
                invoke.reject(
                    "token endpoint returned no response",
                    ErrorMapping.CODE_TOKEN_EXCHANGE_FAILED
                )
                return@performTokenRequest
            }
            emit(AuthEvent.TokenExchangeCompleted)
            invoke.resolveObject(authStateResponse(response, tokenResponse))
        }
    }

    // MARK: - authorizeBrowserOnly

    @Command
    fun authorizeBrowserOnly(invoke: Invoke) {
        val args = try {
            invoke.parseArgs(BrowserOnlyArgs::class.java)
        } catch (e: Exception) {
            invoke.reject("invalid request: ${e.message}", ErrorMapping.CODE_INVALID_REQUEST, e)
            return
        }
        val authUri = parseUri(args.authUrl) ?: run {
            invoke.reject("invalid auth URL: ${args.authUrl}", ErrorMapping.CODE_INVALID_REQUEST)
            return
        }

        emit(AuthEvent.BrowserOpened)
        val intent = BrowserSessionActivity.newIntent(activity, authUri)
        startActivityForResult(invoke, intent, "handleBrowserOnlyResult")
    }

    @ActivityCallback
    fun handleBrowserOnlyResult(invoke: Invoke, result: ActivityResult) {
        when (result.resultCode) {
            Activity.RESULT_OK -> {
                val data = result.data?.data
                if (data == null) {
                    invoke.reject(
                        "browser session ended without a redirect",
                        ErrorMapping.CODE_AUTHORIZATION_FAILED
                    )
                    return
                }
                emit(AuthEvent.RedirectIntercepted)
                invoke.resolveObject(BrowserOnlyResponse(url = data.toString()))
            }
            BrowserSessionActivity.RESULT_BROWSER_NOT_AVAILABLE -> {
                val message = result.data?.getStringExtra(BrowserSessionActivity.EXTRA_ERROR_MESSAGE)
                    ?: "no compatible browser is available"
                invoke.reject(message, ErrorMapping.CODE_BROWSER_NOT_AVAILABLE)
            }
            else -> {
                invoke.reject(
                    "user canceled the authorization flow",
                    ErrorMapping.CODE_USER_CANCELED
                )
            }
        }
    }

    // MARK: - refresh

    @Command
    fun refresh(invoke: Invoke) {
        val args = try {
            invoke.parseArgs(RefreshArgs::class.java)
        } catch (e: Exception) {
            invoke.reject("invalid request: ${e.message}", ErrorMapping.CODE_INVALID_REQUEST, e)
            return
        }

        resolveServiceConfiguration(invoke, args.config) { config ->
            val tokenRequest = TokenRequest.Builder(config, args.clientId)
                .setGrantType(GrantTypeValues.REFRESH_TOKEN)
                .setRefreshToken(args.refreshToken)
                .apply {
                    if (args.scopes.isNotEmpty()) setScope(args.scopes.joinToString(" "))
                    if (args.additionalParameters.isNotEmpty()) {
                        setAdditionalParameters(args.additionalParameters)
                    }
                }
                .build()

            emit(AuthEvent.TokenExchangeStarted)
            authService().performTokenRequest(tokenRequest) { response, ex ->
                if (ex != null) {
                    ErrorMapping.reject(invoke, ex)
                    return@performTokenRequest
                }
                if (response == null) {
                    invoke.reject(
                        "token endpoint returned no response",
                        ErrorMapping.CODE_TOKEN_EXCHANGE_FAILED
                    )
                    return@performTokenRequest
                }
                emit(AuthEvent.TokenExchangeCompleted)
                invoke.resolveObject(authStateResponse(authResponse = null, tokenResponse = response))
            }
        }
    }

    // MARK: - endSession

    @Command
    fun endSession(invoke: Invoke) {
        val args = try {
            invoke.parseArgs(EndSessionArgs::class.java)
        } catch (e: Exception) {
            invoke.reject("invalid request: ${e.message}", ErrorMapping.CODE_INVALID_REQUEST, e)
            return
        }
        val postLogoutUri = parseUri(args.postLogoutRedirectUri) ?: run {
            invoke.reject(
                "invalid post-logout redirect URI: ${args.postLogoutRedirectUri}",
                ErrorMapping.CODE_INVALID_REQUEST
            )
            return
        }

        resolveServiceConfiguration(invoke, args.config) { config ->
            if (config.endSessionEndpoint == null) {
                invoke.reject(
                    "issuer does not advertise an end-session endpoint",
                    ErrorMapping.CODE_INVALID_REQUEST
                )
                return@resolveServiceConfiguration
            }
            val request = EndSessionRequest.Builder(config)
                .setIdTokenHint(args.idTokenHint)
                .setPostLogoutRedirectUri(postLogoutUri)
                .apply {
                    args.state?.let { setState(it) }
                    if (args.additionalParameters.isNotEmpty()) {
                        setAdditionalParameters(args.additionalParameters)
                    }
                }
                .build()

            val intent = try {
                authService().getEndSessionRequestIntent(request)
            } catch (e: android.content.ActivityNotFoundException) {
                invoke.reject(
                    "no compatible browser is available",
                    ErrorMapping.CODE_BROWSER_NOT_AVAILABLE,
                    e
                )
                return@resolveServiceConfiguration
            }

            emit(AuthEvent.BrowserOpened)
            startActivityForResult(invoke, intent, "handleEndSessionResult")
        }
    }

    @ActivityCallback
    fun handleEndSessionResult(invoke: Invoke, result: ActivityResult) {
        val data = result.data
        val response = data?.let { EndSessionResponse.fromIntent(it) }
        val exception = data?.let { AuthorizationException.fromIntent(it) }

        if (exception != null) {
            ErrorMapping.reject(invoke, exception)
            return
        }
        if (response == null) {
            invoke.reject(
                "end session completed without a response",
                ErrorMapping.CODE_AUTHORIZATION_FAILED
            )
            return
        }
        emit(AuthEvent.RedirectIntercepted)
        invoke.resolveObject(EndSessionResponseModel(
            url = response.request.postLogoutRedirectUri.toString(),
            state = response.state
        ))
    }

    // MARK: - register (RFC 7591 dynamic client registration)

    @Command
    fun register(invoke: Invoke) {
        val args = try {
            invoke.parseArgs(RegisterArgs::class.java)
        } catch (e: Exception) {
            invoke.reject("invalid request: ${e.message}", ErrorMapping.CODE_INVALID_REQUEST, e)
            return
        }
        val redirectUris = args.redirectUris.map { parseUri(it) }
        if (redirectUris.any { it == null } || redirectUris.isEmpty()) {
            invoke.reject(
                "one or more redirect URIs are invalid",
                ErrorMapping.CODE_INVALID_REQUEST
            )
            return
        }

        resolveServiceConfiguration(invoke, args.config) { config ->
            val builder = RegistrationRequest.Builder(config, redirectUris.filterNotNull())
            if (args.responseTypes.isNotEmpty()) builder.setResponseTypeValues(args.responseTypes)
            if (args.grantTypes.isNotEmpty()) builder.setGrantTypeValues(args.grantTypes)
            // AppAuth-Android, like the iOS counterpart, takes a single subject
            // type. The OIDC spec field is plural; we forward the first value.
            args.subjectTypes.firstOrNull()?.let { builder.setSubjectType(it) }
            args.tokenEndpointAuthMethod?.let { builder.setTokenEndpointAuthenticationMethod(it) }
            if (args.additionalParameters.isNotEmpty()) {
                builder.setAdditionalParameters(args.additionalParameters)
            }

            authService().performRegistrationRequest(builder.build()) { response, ex ->
                if (ex != null) {
                    ErrorMapping.reject(invoke, ex)
                    return@performRegistrationRequest
                }
                if (response == null) {
                    invoke.reject(
                        "registration endpoint returned no response",
                        ErrorMapping.CODE_INVALID_REGISTRATION_RESPONSE
                    )
                    return@performRegistrationRequest
                }
                invoke.resolveObject(registrationResponse(response))
            }
        }
    }

    // MARK: - Helpers

    /// Resolve a `ConfigSource` into an `AuthorizationServiceConfiguration`.
    /// Discovery hits the network; explicit configs are constructed in place.
    /// `onSuccess` always runs on the main thread (AppAuth's discovery callback
    /// is invoked on the main looper).
    private fun resolveServiceConfiguration(
        invoke: Invoke,
        source: ConfigSource,
        onSuccess: (AuthorizationServiceConfiguration) -> Unit
    ) {
        when (source) {
            is ConfigSource.Discovery -> {
                val issuerUri = parseUri(source.issuer) ?: run {
                    invoke.reject(
                        "invalid issuer URL: ${source.issuer}",
                        ErrorMapping.CODE_INVALID_REQUEST
                    )
                    return
                }
                AuthorizationServiceConfiguration.fetchFromIssuer(issuerUri) { config, ex ->
                    when {
                        ex != null -> ErrorMapping.reject(invoke, ex)
                        config == null -> invoke.reject(
                            "discovery returned no configuration",
                            ErrorMapping.CODE_SERVER_ERROR
                        )
                        else -> onSuccess(config)
                    }
                }
            }
            is ConfigSource.Explicit -> {
                val authEndpoint = parseUri(source.authorizationEndpoint)
                val tokenEndpoint = parseUri(source.tokenEndpoint)
                if (authEndpoint == null || tokenEndpoint == null) {
                    invoke.reject(
                        "invalid endpoint URL",
                        ErrorMapping.CODE_INVALID_REQUEST
                    )
                    return
                }
                onSuccess(
                    AuthorizationServiceConfiguration(
                        authEndpoint,
                        tokenEndpoint,
                        source.registrationEndpoint?.let(::parseUri),
                        source.endSessionEndpoint?.let(::parseUri)
                    )
                )
            }
        }
    }

    private fun parseUri(value: String?): Uri? {
        if (value.isNullOrEmpty()) return null
        return try {
            val uri = Uri.parse(value)
            if (uri.scheme.isNullOrEmpty()) null else uri
        } catch (_: Exception) {
            null
        }
    }

    private fun emit(event: AuthEvent) {
        val channel = eventChannel ?: return
        try {
            channel.sendObject(event)
        } catch (_: Exception) {
            // Diagnostic events are best-effort; never let serialization
            // failures break the underlying flow.
        }
    }

    // MARK: - AppAuth -> wire-format marshalling

    private fun serviceConfigurationResponse(
        config: AuthorizationServiceConfiguration
    ): ServiceConfigurationResponse {
        val discoveryDoc = config.discoveryDoc
        val additional: Map<String, String> = if (discoveryDoc != null) {
            stringifyJson(discoveryDoc.docJson)
        } else {
            emptyMap()
        }
        return ServiceConfigurationResponse(
            authorizationEndpoint = config.authorizationEndpoint.toString(),
            tokenEndpoint = config.tokenEndpoint.toString(),
            endSessionEndpoint = config.endSessionEndpoint?.toString(),
            registrationEndpoint = config.registrationEndpoint?.toString(),
            issuer = discoveryDoc?.issuer?.toString(),
            additionalParameters = additional,
        )
    }

    private fun authStateResponse(
        authResponse: AuthorizationResponse?,
        tokenResponse: TokenResponse,
    ): AuthStateResponse {
        return AuthStateResponse(
            accessToken = tokenResponse.accessToken,
            accessTokenExpiresAt = tokenResponse.accessTokenExpirationTime?.let { it / 1000 },
            idToken = tokenResponse.idToken,
            refreshToken = tokenResponse.refreshToken,
            scope = tokenResponse.scope,
            tokenType = tokenResponse.tokenType,
            authorizationCode = authResponse?.authorizationCode,
            additionalParameters = tokenResponse.additionalParameters
                ?.mapValues { it.value ?: "" }
                ?: emptyMap(),
        )
    }

    private fun registrationResponse(response: RegistrationResponse): RegistrationResponseModel {
        return RegistrationResponseModel(
            clientId = response.clientId,
            clientIdIssuedAt = response.clientIdIssuedAt,
            clientSecret = response.clientSecret,
            clientSecretExpiresAt = response.clientSecretExpiresAt,
            registrationAccessToken = response.registrationAccessToken,
            registrationClientUri = response.registrationClientUri?.toString(),
            tokenEndpointAuthMethod = response.tokenEndpointAuthMethod,
            additionalParameters = response.additionalParameters
                ?.mapValues { it.value ?: "" }
                ?: emptyMap(),
        )
    }

    /// Coerce a `JSONObject` (the raw discovery doc) to `Map<String, String>`.
    /// Nested arrays / objects are JSON-stringified so values stay
    /// round-trippable, matching the iOS bridge's behaviour.
    private fun stringifyJson(json: org.json.JSONObject): Map<String, String> {
        val out = LinkedHashMap<String, String>(json.length())
        val keys = json.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            val raw = json.opt(key) ?: continue
            out[key] = when (raw) {
                is String -> raw
                is org.json.JSONObject, is org.json.JSONArray -> raw.toString()
                else -> raw.toString()
            }
        }
        return out
    }
}
