use crate::WebviewWindowExt;
use tauri::{
    plugin::{Builder, TauriPlugin},
    Emitter, Error, Listener, Runtime, WebviewWindow,
};

pub mod commands;

impl<R: Runtime> WebviewWindowExt for WebviewWindow<R> {
    fn create_overlay_titlebar(&self) -> Result<&Self, Error> {
        self.set_decorations(false)?;

        Ok(self)
    }
}
