"""Install the separate host-reviewed task handoff into the companion CXTasks app."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = root / "integrations/app-context"
target = root.parent / "cxtasks/src-tauri/src"
selection = target / "quickask.rs"
current = selection.read_text()
expected = (source / "cxtasks-quickask.rs").read_text()
assert "pub fn publish_quickask_selection" in current
assert "fn snapshot(app: &tauri::AppHandle)" in current
# Keep the frontend and setup wiring established by install-app-context.py.
# Refuse a differently modified snapshot rather than overwriting it.
assert current.split("fn snapshot(app: &tauri::AppHandle)", 1)[1] == expected.split("fn snapshot(app: &tauri::AppHandle)", 1)[1]
selection.write_text(expected)
(target / "quickask_handoff.rs").write_text((source / "cxtasks-handoff.rs").read_text())
print("Installed CXTasks reviewed task handoff")
