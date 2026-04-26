use serde::{Serialize, Serializer};

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, thiserror::Error)]
#[non_exhaustive]
pub enum Error {
    #[error("user canceled the authentication session")]
    UserCanceled,
    #[error("the platform could not present the authentication session")]
    PresentationFailed,
    #[error("an authentication session is already in progress")]
    SessionBusy,
    #[error("the authentication session failed: {0}")]
    SessionFailed(String),
    #[error("OAuth sessions are only supported on iOS and Android")]
    UnsupportedPlatform,
    #[cfg(mobile)]
    #[error(transparent)]
    PluginInvoke(#[from] tauri::plugin::mobile::PluginInvokeError),
}

/// Stable, machine-readable error code that the JS layer can switch on
/// without parsing free-form messages.
impl Error {
    pub fn code(&self) -> &'static str {
        match self {
            Error::UserCanceled => "USER_CANCELED",
            Error::PresentationFailed => "PRESENTATION_FAILED",
            Error::SessionBusy => "SESSION_BUSY",
            Error::SessionFailed(_) => "SESSION_FAILED",
            Error::UnsupportedPlatform => "UNSUPPORTED_PLATFORM",
            #[cfg(mobile)]
            Error::PluginInvoke(_) => "PLUGIN_INVOKE_FAILED",
        }
    }
}

#[derive(Serialize)]
struct SerializedError<'a> {
    code: &'a str,
    message: String,
}

impl Serialize for Error {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        SerializedError {
            code: self.code(),
            message: self.to_string(),
        }
        .serialize(serializer)
    }
}
