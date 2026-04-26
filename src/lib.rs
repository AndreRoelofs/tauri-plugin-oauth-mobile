use base64::Engine;
use focus_tracker::{FocusTracker, FocusTrackerConfig, IconConfig};
use image::ImageEncoder;
use std::io::Cursor;
use std::sync::{Arc, Mutex};
use tauri::{
    plugin::{Builder, TauriPlugin},
    Emitter, Error, Listener, Manager, Runtime, WebviewWindow,
};

#[cfg(target_os = "macos")]
#[path = "macos/mod.rs"]
mod platform;

#[cfg(target_os = "linux")]
#[path = "linux/mod.rs"]
mod platform;

#[cfg(target_os = "windows")]
#[path = "windows/mod.rs"]
mod platform;

mod commands;

const MAX_FOCUS_HISTORY: usize = 5;

#[derive(serde::Serialize, serde::Deserialize, Clone)]
pub struct FocusedWindow {
    pub process_id: u32,
    pub process_name: String,
    pub window_title: Option<String>,
    /// Base64 encoded PNG icon data
    pub icon: Option<String>,
}

pub struct GlazierState {
    pub items: Arc<Mutex<Vec<FocusedWindow>>>,
}

pub trait WebviewWindowExt {
    fn create_overlay_titlebar(&self) -> Result<&Self, Error>;
}

fn encode_icon_to_base64(icon: &image::RgbaImage) -> Option<String> {
    let mut buf = Cursor::new(Vec::new());
    let encoder = image::codecs::png::PngEncoder::new(&mut buf);
    encoder
        .write_image(
            icon.as_raw(),
            icon.width(),
            icon.height(),
            image::ExtendedColorType::Rgba8,
        )
        .ok()?;
    Some(base64::engine::general_purpose::STANDARD.encode(buf.into_inner()))
}

pub fn init<R: Runtime>() -> TauriPlugin<R> {
    Builder::new("glazier")
        .setup(|app, _api| {
            let items = Arc::new(Mutex::new(Vec::new()));

            app.manage(GlazierState {
                items: Arc::clone(&items),
            });

            tauri::async_runtime::spawn(async move {
                let config = FocusTrackerConfig::builder()
                    .poll_interval(std::time::Duration::from_millis(100))
                    .unwrap()
                    .icon(IconConfig::builder().size(64).unwrap().build())
                    .build();

                let tracker = FocusTracker::builder().config(config).build();

                let result = tracker
                    .track_focus()
                    .on_focus(move |window: focus_tracker::FocusedWindow| {
                        let icon_base64 = window
                            .icon
                            .as_ref()
                            .map(|arc| encode_icon_to_base64(arc))
                            .flatten();

                        let focused = FocusedWindow {
                            process_id: window.process_id,
                            process_name: window.process_name.clone(),
                            window_title: window.window_title.clone(),
                            icon: icon_base64,
                        };

                        let items = Arc::clone(&items);
                        async move {
                            let mut list = items.lock().unwrap();
                            list.insert(0, focused);
                            list.truncate(MAX_FOCUS_HISTORY);
                            Ok(())
                        }
                    })
                    .call()
                    .await;

                if let Err(e) = result {
                    log::error!("Focus tracker error: {}", e);
                }
            });

            log::info!("glazier plugin initialized");
            Ok(())
        })
        .build()
}
