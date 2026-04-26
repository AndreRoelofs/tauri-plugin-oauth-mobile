//! Tauri 2 mobile plugin that bridges OAuth 2.0 / OIDC flows to the
//! reference RFC 8252 implementations: AppAuth-iOS and AppAuth-Android.
//!
//! AppAuth handles PKCE (S256), `state`/`nonce` validation, discovery
//! (RFC 8414 / OIDC), authorization, token exchange, refresh, end-session
//! (RFC 8665), and dynamic client registration (RFC 7591). This crate is a
//! thin Rust + native bridge — we do not write OAuth state machines.
//!
//! Desktop targets reject every command with [`Error::UnsupportedPlatform`];
//! desktop OAuth has its own canonical plugin (`tauri-plugin-oauth`).

#![cfg_attr(not(mobile), allow(dead_code))]

use serde::{Serialize, de::DeserializeOwned};
use tauri::{
    AppHandle, Manager, Runtime,
    ipc::Channel,
    plugin::{Builder, PluginApi, TauriPlugin},
};

mod commands;
mod error;
mod events;
mod models;

pub use error::{Error, Result};
pub use events::AuthEvent;
pub use models::{
    AuthState, AuthorizeRequest, BrowserOnlyRequest, BrowserOnlyResponse, ConfigSource,
    DiscoverRequest, EndSessionRequest, EndSessionResponse, Prompt, RefreshRequest,
    RegisterRequest, RegistrationResponse, ServiceConfiguration,
};

#[cfg(target_os = "ios")]
tauri::ios_plugin_binding!(init_plugin_appauth);

#[cfg(target_os = "android")]
const PLUGIN_IDENTIFIER: &str = "app.tauri.appauth";

/// Handle to the AppAuth-backed plugin. Acquired via [`AppAuthExt::appauth`].
pub struct AppAuth<R: Runtime>(AppAuthImpl<R>);

#[cfg(mobile)]
type AppAuthImpl<R> = tauri::plugin::PluginHandle<R>;

// `PhantomData<fn() -> R>` is unconditionally `Send + Sync`, which is what
// Tauri's `Manager::manage` requires.
#[cfg(not(mobile))]
type AppAuthImpl<R> = std::marker::PhantomData<fn() -> R>;

impl<R: Runtime> AppAuth<R> {
    /// Resolve `<issuer>/.well-known/openid-configuration` (or RFC 8414
    /// equivalent) into a [`ServiceConfiguration`].
    pub async fn discover(&self, req: DiscoverRequest) -> Result<ServiceConfiguration> {
        invoke_native(self, "discover", &req)
    }

    /// Perform RFC 7591 dynamic client registration against an issuer that
    /// supports it. Most providers do not; check the discovery document's
    /// `registration_endpoint`.
    pub async fn register(&self, req: RegisterRequest) -> Result<RegistrationResponse> {
        invoke_native(self, "register", &req)
    }

    /// Open the platform browser, run PKCE, validate `state`/`nonce`, and
    /// exchange the authorization code for tokens. Returns the full
    /// post-exchange [`AuthState`].
    pub async fn authorize(&self, req: AuthorizeRequest) -> Result<AuthState> {
        invoke_native(self, "authorize", &req)
    }

    /// Open the browser at `auth_url`, capture the redirect to `redirect_uri`,
    /// and return the raw callback URL without performing a token exchange.
    /// Use this when a backend mediates the code-for-token swap.
    pub async fn authorize_browser_only(
        &self,
        req: BrowserOnlyRequest,
    ) -> Result<BrowserOnlyResponse> {
        invoke_native(self, "authorizeBrowserOnly", &req)
    }

    /// Trade a refresh token for a fresh access token via the issuer's token
    /// endpoint.
    pub async fn refresh(&self, req: RefreshRequest) -> Result<AuthState> {
        invoke_native(self, "refresh", &req)
    }

    /// RFC 8665 RP-initiated logout. Resolves once the post-logout redirect
    /// fires.
    pub async fn end_session(&self, req: EndSessionRequest) -> Result<EndSessionResponse> {
        invoke_native(self, "endSession", &req)
    }

    /// Register a [`Channel`] that the native side will use to emit
    /// [`AuthEvent`]s as flows progress. Call once per session; calling again
    /// replaces the previous subscription.
    pub async fn subscribe_events(&self, channel: Channel<AuthEvent>) -> Result<()> {
        #[derive(Serialize)]
        struct Payload<T: Serialize> {
            channel: T,
        }
        invoke_native(self, "subscribeEvents", &Payload { channel })
    }
}

fn invoke_native<P, Resp, R>(plugin: &AppAuth<R>, command: &str, payload: &P) -> Result<Resp>
where
    P: Serialize,
    Resp: DeserializeOwned,
    R: Runtime,
{
    #[cfg(mobile)]
    {
        Ok(plugin.0.run_mobile_plugin(command, payload)?)
    }
    #[cfg(not(mobile))]
    {
        let _ = (plugin, command, payload);
        Err(Error::UnsupportedPlatform)
    }
}

/// Extension trait that hangs an [`AppAuth`] handle off any [`Manager`].
pub trait AppAuthExt<R: Runtime> {
    fn appauth(&self) -> &AppAuth<R>;
}

impl<R: Runtime, T: Manager<R>> AppAuthExt<R> for T {
    fn appauth(&self) -> &AppAuth<R> {
        self.state::<AppAuth<R>>().inner()
    }
}

fn init_appauth<R: Runtime, C: DeserializeOwned>(
    _app: &AppHandle<R>,
    _api: PluginApi<R, C>,
) -> Result<AppAuth<R>> {
    #[cfg(target_os = "ios")]
    {
        let handle = _api.register_ios_plugin(init_plugin_appauth)?;
        Ok(AppAuth(handle))
    }
    #[cfg(target_os = "android")]
    {
        let handle = _api.register_android_plugin(PLUGIN_IDENTIFIER, "AppAuthPlugin")?;
        Ok(AppAuth(handle))
    }
    #[cfg(not(mobile))]
    {
        Ok(AppAuth(std::marker::PhantomData))
    }
}

pub fn init<R: Runtime>() -> TauriPlugin<R> {
    Builder::new("appauth")
        .invoke_handler(tauri::generate_handler![
            commands::discover,
            commands::register,
            commands::authorize,
            commands::authorize_browser_only,
            commands::refresh,
            commands::end_session,
            commands::subscribe_events,
        ])
        .setup(|app, api| {
            let plugin = init_appauth(app, api)?;
            app.manage(plugin);
            Ok(())
        })
        .build()
}
