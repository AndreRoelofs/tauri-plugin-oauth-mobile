//! Drive OAuth flows through ASWebAuthenticationSession on iOS and Chrome
//! Custom Tabs on Android.
//!
//! On both platforms the plugin opens an in-app browser session, intercepts
//! the redirect to the configured callback scheme, and resolves with the full
//! callback URL — replacing the older "open external browser, poll backend"
//! pattern.
//!
//! Platform asymmetry: `prefersEphemeralSession` is honored on iOS but has no
//! Android equivalent — Custom Tabs always shares cookies with the user's
//! default browser.

#![cfg_attr(not(mobile), allow(dead_code))]

use serde::de::DeserializeOwned;
use tauri::{
    AppHandle, Manager, Runtime,
    plugin::{Builder, PluginApi, TauriPlugin},
};

mod commands;
mod error;
mod models;

pub use error::{Error, Result};
pub use models::{AuthenticateOptions, AuthenticateResponse};

#[cfg(target_os = "ios")]
tauri::ios_plugin_binding!(init_plugin_oauth_session);

#[cfg(target_os = "android")]
const PLUGIN_IDENTIFIER: &str = "app.tauri.oauth_session";

/// Access to the OAuth session APIs.
pub struct OAuthSession<R: Runtime>(OAuthSessionImpl<R>);

#[cfg(mobile)]
type OAuthSessionImpl<R> = tauri::plugin::PluginHandle<R>;

// `PhantomData<fn() -> R>` is unconditionally `Send + Sync`, which is what
// Tauri's `Manager::manage` requires.
#[cfg(not(mobile))]
type OAuthSessionImpl<R> = std::marker::PhantomData<fn() -> R>;

impl<R: Runtime> OAuthSession<R> {
    /// Open the platform-native authentication browser and resolve with the
    /// redirect URL once the system intercepts the callback scheme.
    pub async fn authenticate(
        &self,
        options: AuthenticateOptions,
    ) -> Result<AuthenticateResponse> {
        #[cfg(mobile)]
        {
            let response: AuthenticateResponse =
                self.0.run_mobile_plugin("authenticate", options)?;
            Ok(response)
        }
        #[cfg(not(mobile))]
        {
            let _ = options;
            Err(Error::UnsupportedPlatform)
        }
    }
}

pub trait OAuthSessionExt<R: Runtime> {
    fn oauth_session(&self) -> &OAuthSession<R>;
}

impl<R: Runtime, T: Manager<R>> OAuthSessionExt<R> for T {
    fn oauth_session(&self) -> &OAuthSession<R> {
        self.state::<OAuthSession<R>>().inner()
    }
}

fn init_oauth_session<R: Runtime, C: DeserializeOwned>(
    _app: &AppHandle<R>,
    _api: PluginApi<R, C>,
) -> Result<OAuthSession<R>> {
    #[cfg(target_os = "ios")]
    {
        let handle = _api.register_ios_plugin(init_plugin_oauth_session)?;
        Ok(OAuthSession(handle))
    }
    #[cfg(target_os = "android")]
    {
        let handle = _api.register_android_plugin(PLUGIN_IDENTIFIER, "OAuthSessionPlugin")?;
        Ok(OAuthSession(handle))
    }
    #[cfg(not(mobile))]
    {
        Ok(OAuthSession(std::marker::PhantomData))
    }
}

pub fn init<R: Runtime>() -> TauriPlugin<R> {
    Builder::new("oauth-session")
        .invoke_handler(tauri::generate_handler![commands::authenticate])
        .setup(|app, api| {
            let plugin = init_oauth_session(app, api)?;
            app.manage(plugin);
            Ok(())
        })
        .build()
}
