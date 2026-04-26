use crate::platform;
use crate::GlazierState;
use tauri::State;

#[tauri::command]
pub async fn position_window_next_to_previous(
    state: State<'_, GlazierState>,
) -> Result<(), String> {
    platform::commands::position_window_next_to_previous(state).await
}

/// Returns an array of icons from previously focused windows.
#[tauri::command]
pub async fn get_previous_icons(
    state: State<'_, GlazierState>,
    num: usize,
) -> Result<Vec<String>, String> {
    platform::commands::get_previous_icons(state, num).await
}
