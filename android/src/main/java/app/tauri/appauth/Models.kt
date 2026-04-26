// SPDX-License-Identifier: Apache-2.0

package app.tauri.appauth

import app.tauri.annotation.InvokeArg
import com.fasterxml.jackson.annotation.JsonSubTypes
import com.fasterxml.jackson.annotation.JsonTypeInfo

// MARK: - Inputs decoded from JS payloads

@InvokeArg
class DiscoverArgs {
    lateinit var issuer: String
}

/// Mirrors the Rust `ConfigSource` tagged union. Jackson dispatches on the
/// `kind` discriminator the Rust side writes via `#[serde(tag = "kind")]`.
@JsonTypeInfo(
    use = JsonTypeInfo.Id.NAME,
    include = JsonTypeInfo.As.PROPERTY,
    property = "kind"
)
@JsonSubTypes(
    JsonSubTypes.Type(value = ConfigSource.Discovery::class, name = "discovery"),
    JsonSubTypes.Type(value = ConfigSource.Explicit::class, name = "explicit"),
)
sealed class ConfigSource {
    @InvokeArg
    class Discovery : ConfigSource() {
        lateinit var issuer: String
    }

    @InvokeArg
    class Explicit : ConfigSource() {
        lateinit var authorizationEndpoint: String
        lateinit var tokenEndpoint: String
        var endSessionEndpoint: String? = null
        var registrationEndpoint: String? = null
    }
}

/// OIDC `prompt` parameter values. The Rust enum is `snake_case`; Jackson maps
/// the JSON strings onto these constants via `@JsonValue`-style passthrough.
enum class Prompt(val value: String) {
    LOGIN("login"),
    CONSENT("consent"),
    SELECT_ACCOUNT("select_account"),
    NONE("none");

    companion object {
        @com.fasterxml.jackson.annotation.JsonCreator
        @JvmStatic
        fun fromString(value: String): Prompt? =
            values().firstOrNull { it.value == value }
    }

    @com.fasterxml.jackson.annotation.JsonValue
    fun toValue(): String = value
}

@InvokeArg
class AuthorizeArgs {
    lateinit var config: ConfigSource
    lateinit var clientId: String
    lateinit var redirectUri: String
    var scopes: List<String> = emptyList()
    var additionalParameters: Map<String, String> = emptyMap()
    var prompt: Prompt? = null
    var loginHint: String? = null
    var uiLocales: List<String>? = null
    var prefersEphemeralSession: Boolean = true
    var useNonce: Boolean = true
}

@InvokeArg
class BrowserOnlyArgs {
    lateinit var authUrl: String
    lateinit var redirectUri: String
    var prefersEphemeralSession: Boolean = true
}

@InvokeArg
class RefreshArgs {
    lateinit var config: ConfigSource
    lateinit var clientId: String
    lateinit var refreshToken: String
    var scopes: List<String> = emptyList()
    var additionalParameters: Map<String, String> = emptyMap()
}

@InvokeArg
class RegisterArgs {
    lateinit var config: ConfigSource
    lateinit var redirectUris: List<String>
    var clientName: String? = null
    var responseTypes: List<String> = emptyList()
    var grantTypes: List<String> = emptyList()
    var subjectTypes: List<String> = emptyList()
    var tokenEndpointAuthMethod: String? = null
    var additionalParameters: Map<String, String> = emptyMap()
}

@InvokeArg
class EndSessionArgs {
    lateinit var config: ConfigSource
    lateinit var idTokenHint: String
    lateinit var postLogoutRedirectUri: String
    var state: String? = null
    var additionalParameters: Map<String, String> = emptyMap()
    var prefersEphemeralSession: Boolean = true
}

@InvokeArg
class SubscribeEventsArgs {
    lateinit var channel: app.tauri.plugin.Channel
}

// MARK: - Outputs encoded to JS responses

/// Plain `data class` outputs. Jackson serializes them via field access (the
/// `setVisibility(FIELD, ANY)` configured on the shared mapper).
data class ServiceConfigurationResponse(
    val authorizationEndpoint: String,
    val tokenEndpoint: String,
    val endSessionEndpoint: String?,
    val registrationEndpoint: String?,
    val issuer: String?,
    val additionalParameters: Map<String, String>,
)

data class AuthStateResponse(
    val accessToken: String?,
    val accessTokenExpiresAt: Long?,
    val idToken: String?,
    val refreshToken: String?,
    val scope: String?,
    val tokenType: String?,
    val authorizationCode: String?,
    val additionalParameters: Map<String, String>,
)

data class BrowserOnlyResponse(
    val url: String,
)

data class RegistrationResponseModel(
    val clientId: String,
    val clientIdIssuedAt: Long?,
    val clientSecret: String?,
    val clientSecretExpiresAt: Long?,
    val registrationAccessToken: String?,
    val registrationClientUri: String?,
    val tokenEndpointAuthMethod: String?,
    val additionalParameters: Map<String, String>,
)

data class EndSessionResponseModel(
    val url: String,
    val state: String?,
)

/// Diagnostic event mirroring `crate::events::AuthEvent`. Tagged on `kind`,
/// camelCase values to match the Rust serde shape.
data class AuthEvent(val kind: String) {
    companion object {
        val BrowserOpened = AuthEvent("browserOpened")
        val RedirectIntercepted = AuthEvent("redirectIntercepted")
        val TokenExchangeStarted = AuthEvent("tokenExchangeStarted")
        val TokenExchangeCompleted = AuthEvent("tokenExchangeCompleted")
    }
}
