"""Install the additive selection interfaces in the two companion repositories.

No data migrations, credentials, MCP configuration, or installed apps are changed.
"""
from pathlib import Path

source = Path(__file__).resolve().parents[1] / "integrations/app-context"
projects = source.parents[2]
for name in ("cxmail", "cxtasks"):
    root = projects / name
    backend = root / "src-tauri/src/lib.rs"
    frontend = root / "src/App.tsx"
    rust = (source / f"{name}-quickask.rs").read_text().replace("if let thread = &message.thread_root_id", "if let Some(thread) = &message.thread_root_id")
    hook = (source / f"{name}-useQuickAskSelection.ts").read_text()
    lib = backend.read_text()
    if "mod quickask;" not in lib:
        lib = "mod quickask;\n" + lib
    if "quickask::publish_quickask_selection," not in lib:
        marker = ".invoke_handler(tauri::generate_handler!["
        assert lib.count(marker) == 1, f"Unknown command registration in {name}"
        lib = lib.replace(marker, marker + "\n            quickask::publish_quickask_selection,", 1)
    if "quickask::start(app.handle().clone());" not in lib:
        marker = ".setup(|app| {"
        assert lib.count(marker) == 1, f"Unknown setup in {name}"
        lib = lib.replace(marker, marker + "\n            quickask::start(app.handle().clone());", 1)
    app = frontend.read_text()
    if 'import { useQuickAskSelection }' not in app:
        app = 'import { useQuickAskSelection } from "@/hooks/useQuickAskSelection";\n' + app
        marker = "function App() {"
        assert app.count(marker) == 1, f"Unknown frontend entry point in {name}"
        app = app.replace(marker, marker + "\n  useQuickAskSelection();", 1)
    # Refuse to overwrite a separately modified implementation on repeated runs.
    for path, content in ((root / "src-tauri/src/quickask.rs", rust), (root / "src/hooks/useQuickAskSelection.ts", hook)):
        if path.exists() and path.read_text() != content:
            raise RuntimeError(f"Existing selection interface differs: {path}")
        path.write_text(content)
    backend.write_text(lib)
    frontend.write_text(app)
    print(f"Installed the current-selection interface in {name}")
