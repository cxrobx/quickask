"""Add a read-only native active-document bridge without changing Onyx's runners."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
target = root.parent / "ask-widget/launcher/Onyx.swift"
text = target.read_text()
snippet = (root / "integrations/app-context/onyx-quickask.swift").read_text()
if "private final class OnyxQuickAskContext" not in text:
    text = text.replace("import Cocoa\n", "import Cocoa\nimport Darwin\n", 1)
    text = text.replace("private let port = 8899", snippet + "\nprivate let port = 8899", 1)
    text = text.replace("    private var webView: WKWebView?", "    private var quickAskContext: OnyxQuickAskContext?\n    private var webView: WKWebView?", 1)
    marker = "        webView = view\n"
    assert text.count(marker) == 1
    text = text.replace(marker, marker + '''        quickAskContext = OnyxQuickAskContext { [weak self] reply in
            guard let self, let view = self.webView, let url = view.url,
                  url.host == "127.0.0.1", url.port == port else { reply(nil); return }
            // Only the shell's active reader frame supplies identity. No body text or write capability.
            view.evaluateJavaScript("""
            (() => {
              const f = document.getElementById('reader'), d = f?.contentDocument;
              if (!d) return null;
              return {src: d.querySelector('meta[name="askw-src"]')?.content || '',
                      sig: d.querySelector('meta[name="askw-doc-sig"]')?.content || '',
                      title: d.title || '', editing: !!f.contentWindow.askwEditor?.live()};
            })()
            """) { [weak self] value, _ in
                guard let self, let data = value as? [String: Any], let src = data["src"] as? String, !src.isEmpty else { reply(nil); return }
                let sig = data["sig"] as? String ?? ""
                let editing = data["editing"] as? Bool ?? false
                var records = ["document_revision": sig, "editing": editing ? "true" : "false"]
                if src.hasPrefix("/") {
                    records["document_path"] = URL(fileURLWithPath: src).resolvingSymlinksInPath().standardizedFileURL.path
                } else { records["source_url"] = src }
                reply(["pid": ProcessInfo.processInfo.processIdentifier, "bundleID": "com.cx.onyx", "windowLabel": "main",
                       "windowID": self.window.windowNumber, "revision": "\\(src):\\(sig):\\(editing)",
                       "label": String((data["title"] as? String ?? "Document").prefix(1000)), "records": records])
            }
        }
''', 1)
    target.write_text(text)
    print("Installed read-only Onyx current-document context")
else:
    print("Onyx current-document context is already installed")
