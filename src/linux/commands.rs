use crate::GlazierState;
use tauri::State;

pub async fn position_window_next_to_previous(
    state: State<'_, GlazierState>,
) -> Result<(), String> {
    let items = state.items.lock().unwrap();
    todo!()
}

pub async fn get_previous_icons(
    state: State<'_, GlazierState>,
    num: usize,
) -> Result<Vec<String>, String> {
    let items = state
        .items
        .lock()
        .unwrap()
        .iter()
        .take(num)
        .filter_map(|item| item.icon.clone())
        .collect::<Vec<String>>();
    Ok(items)
}
