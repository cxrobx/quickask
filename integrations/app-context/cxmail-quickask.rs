//! Read-only current-selection interface for Quick Ask. No mail/task actions here.
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::Mutex;
use std::time::Duration;
use tauri::{Manager, State, WebviewWindow};
use crate::LockExt;

#[derive(Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SelectionInput {
    task_id: Option<String>,
    account_id: Option<String>,
    folder: Option<String>,
    uid: Option<u32>,
    #[serde(default)]
    view: String,
    project: Option<String>,
    #[serde(default)]
    composing: bool,
}
#[derive(Default)]
pub struct SelectionState(Mutex<(Option<SelectionInput>, u32)>);

#[tauri::command]
pub fn publish_quickask_selection(window: WebviewWindow, state: State<'_, SelectionState>, selection: SelectionInput) -> Result<(), String> {
    if window.label() != "main" { return Err("Selection must come from the main window".into()); }
    if [&selection.task_id, &selection.account_id, &selection.folder, &selection.project].iter().any(|v| v.as_ref().is_some_and(|s| s.len() > 512)) || selection.view.len() > 128 {
        return Err("Invalid selection".into());
    }
    #[cfg(target_os = "macos")]
    let number: isize = unsafe {
        let ptr = window.ns_window().map_err(|_| "Window unavailable")?;
        objc2::msg_send![ptr as *mut objc2::runtime::AnyObject, windowNumber]
    };
    #[cfg(not(target_os = "macos"))]
    let number: isize = 0;
    *state.0.lock().map_err(|_| "Selection unavailable")? = (Some(selection), number as u32);
    Ok(())
}

pub fn start(app: tauri::AppHandle) {
    app.manage(SelectionState::default());
    // Only the local account can connect. No network port and no action endpoint.
    let Some(home) = std::env::var_os("HOME") else { return };
    let directory = std::path::PathBuf::from(home).join("Library/Application Support/QuickAsk/Context");
    if directory.symlink_metadata().is_ok_and(|m| m.file_type().is_symlink()) { return; }
    if std::fs::create_dir_all(&directory).is_err() { return; }
    if std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).is_err() { return; }
    let path = directory.join("cxmail.sock");
    if UnixStream::connect(&path).is_ok() { return; }
    let _ = std::fs::remove_file(&path);
    let Ok(listener) = UnixListener::bind(&path) else { return };
    if std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).is_err() { return; }
    std::thread::spawn(move || {
        for mut stream in listener.incoming().flatten() {
            let _ = stream.set_read_timeout(Some(Duration::from_millis(250)));
            let _ = stream.set_write_timeout(Some(Duration::from_millis(250)));
            let mut query = String::new();
            if BufReader::new((&stream).take(256)).read_line(&mut query).is_err() { continue; }
            if serde_json::from_str::<Value>(&query).ok().and_then(|v| v["op"].as_str().map(str::to_owned)).as_deref() != Some("context") { continue; }
            let value = snapshot(&app).unwrap_or(Value::Null);
            if let Ok(mut encoded) = serde_json::to_vec(&value) { encoded.push(b'\n'); let _ = stream.write_all(&encoded); }
        }
    });
}

fn snapshot(app: &tauri::AppHandle) -> Option<Value> {
    let published = app.try_state::<SelectionState>()?;
    let (selected, window_id) = published.0.lock().ok()?.clone();
    let selected = selected?;
    let state = app.try_state::<crate::AppState>()?;
    let conn = state.db.safe_lock();
    let mut records = serde_json::Map::new();
    let mut label = selected.view.clone();
    let mut revision = format!("{}:{:?}:{:?}:{}", selected.view, selected.project, selected.task_id, selected.composing);
    if !selected.composing {
        if let (Some(account), Some(folder), Some(uid)) = (selected.account_id.as_deref(), selected.folder.as_deref(), selected.uid) {
            let message = crate::db::messages::get_by_uid(&conn, account, folder, uid).ok()??;
            records.insert("account_id".into(), json!(account));
            records.insert("folder".into(), json!(folder));
            records.insert("uid".into(), json!(uid.to_string()));
            if let Ok(Some(draft)) = crate::db::drafts::find_by_uid(&conn, account, folder, uid) { records.insert("draft_id".into(), json!(draft.draft_id)); }
            if let Some(thread) = &message.thread_root_id { records.insert("thread_id".into(), json!(thread)); }
            label = format!("{} · {}", message.subject.as_deref().unwrap_or("No subject"), message.from_email.as_deref().unwrap_or("Unknown sender"));
            revision = format!("{}:{}:{}:{}:{}:{}", account, folder, uid, message.date, message.is_read, message.is_flagged);
        }
    } else { label = "Compose email".into(); }

    Some(json!({"pid":std::process::id(), "bundleID":"com.cxmail.app", "windowLabel":"main", "windowID":window_id, "revision":revision, "label":label.chars().take(1000).collect::<String>(), "records":records}))
}
