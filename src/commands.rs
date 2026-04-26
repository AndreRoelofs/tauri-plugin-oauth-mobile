use tauri::{AppHandle, Runtime, command};

use crate::{AuthenticateOptions, AuthenticateResponse, OAuthSessionExt, Result};

#[command]
pub(crate) async fn authenticate<R: Runtime>(
    app: AppHandle<R>,
    options: AuthenticateOptions,
) -> Result<AuthenticateResponse> {
    app.oauth_session().authenticate(options).await
}
