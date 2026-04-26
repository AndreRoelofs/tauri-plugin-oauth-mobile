use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// Where to source the authorization server's endpoints.
///
/// `Discovery` hits `<issuer>/.well-known/openid-configuration` (RFC 8414 /
/// OIDC); `Explicit` skips discovery for providers that don't publish a
/// document or for tests that want full control.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ConfigSource {
    #[serde(rename_all = "camelCase")]
    Discovery { issuer: String },
    #[serde(rename_all = "camelCase")]
    Explicit {
        authorization_endpoint: String,
        token_endpoint: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        end_session_endpoint: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        registration_endpoint: Option<String>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceConfiguration {
    pub authorization_endpoint: String,
    pub token_endpoint: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end_session_endpoint: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub registration_endpoint: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub issuer: Option<String>,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub additional_parameters: HashMap<String, serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscoverRequest {
    pub issuer: String,
}

/// OIDC `prompt` parameter values (RFC 6749 / OIDC Core §3.1.2.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Prompt {
    Login,
    Consent,
    SelectAccount,
    None,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthorizeRequest {
    pub config: ConfigSource,
    pub client_id: String,
    /// Custom-scheme URI (e.g. `com.example.app:/oauth/callback`) or HTTPS
    /// app-link. AppAuth validates that the redirect handler is registered
    /// with the OS before opening the browser.
    pub redirect_uri: String,
    #[serde(default)]
    pub scopes: Vec<String>,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub additional_parameters: HashMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt: Option<Prompt>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub login_hint: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ui_locales: Option<Vec<String>>,
    /// iOS-only hint forwarded to `ASWebAuthenticationSession`. Ignored on
    /// Android (Custom Tabs always shares cookies with the user's default
    /// browser).
    #[serde(default = "default_true")]
    pub prefers_ephemeral_session: bool,
    /// When `true`, AppAuth generates and validates an OIDC `nonce`. Default
    /// `true` if `scopes` contains `openid`; otherwise the field is set but
    /// the native side can opt out per-provider.
    #[serde(default = "default_true")]
    pub use_nonce: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct AuthState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub access_token: Option<String>,
    /// Unix seconds at which `access_token` expires.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub access_token_expires_at: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refresh_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token_type: Option<String>,
    /// Surfaced for backend-mediated flows that exchange the code themselves.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub authorization_code: Option<String>,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub additional_parameters: HashMap<String, serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserOnlyRequest {
    /// Fully-built authorization URL. The plugin opens the browser at this URL
    /// and waits for the OS to intercept `redirect_uri`.
    pub auth_url: String,
    pub redirect_uri: String,
    #[serde(default = "default_true")]
    pub prefers_ephemeral_session: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserOnlyResponse {
    /// Full callback URL the system intercepted, with all query parameters
    /// from the authorization server intact.
    pub url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RefreshRequest {
    pub config: ConfigSource,
    pub client_id: String,
    pub refresh_token: String,
    /// Optionally narrow the requested scopes (RFC 6749 §6).
    #[serde(default)]
    pub scopes: Vec<String>,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub additional_parameters: HashMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterRequest {
    pub config: ConfigSource,
    pub redirect_uris: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client_name: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub response_types: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub grant_types: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub subject_types: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token_endpoint_auth_method: Option<String>,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub additional_parameters: HashMap<String, serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegistrationResponse {
    pub client_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client_id_issued_at: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client_secret: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client_secret_expires_at: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub registration_access_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub registration_client_uri: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token_endpoint_auth_method: Option<String>,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub additional_parameters: HashMap<String, serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EndSessionRequest {
    pub config: ConfigSource,
    pub id_token_hint: String,
    pub post_logout_redirect_uri: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub additional_parameters: HashMap<String, String>,
    #[serde(default = "default_true")]
    pub prefers_ephemeral_session: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EndSessionResponse {
    pub url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
}

fn default_true() -> bool {
    true
}
