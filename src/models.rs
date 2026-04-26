use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthenticateOptions {
    /// Fully-qualified URL of the OAuth authorization endpoint to load.
    pub auth_url: String,
    /// URL scheme the system should intercept (e.g. `eurora`). Must NOT
    /// include `://`.
    pub callback_scheme: String,
    /// When `true`, the session uses an ephemeral cookie store with no
    /// shared state with Safari. Defaults to `true`, which is the
    /// privacy-respecting default for OAuth.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prefers_ephemeral_session: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthenticateResponse {
    /// The redirect URL the system intercepted, with all query parameters
    /// from the OAuth provider intact.
    pub url: String,
}
