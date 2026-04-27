//! Platform-specific implementation of the [`AppAuth`] handle.
//!
//! On mobile targets, the handle wraps a real `PluginHandle` and forwards
//! every call to AppAuth-iOS or AppAuth-Android via Tauri's async bridge.
//! On desktop targets, it is a zero-sized stub that returns
//! [`crate::Error::UnsupportedPlatform`] from every method.

#[cfg(mobile)]
mod mobile;
#[cfg(mobile)]
pub use mobile::AppAuth;
#[cfg(mobile)]
pub(crate) use mobile::init;

#[cfg(not(mobile))]
mod desktop;
#[cfg(not(mobile))]
pub use desktop::AppAuth;
#[cfg(not(mobile))]
pub(crate) use desktop::init;
