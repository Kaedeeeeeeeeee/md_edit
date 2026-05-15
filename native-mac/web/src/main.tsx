import React, { useEffect, useState } from "react";
import ReactDOM from "react-dom/client";
import { EmbeddedEditor } from "./EmbeddedEditor";
import { resolveLocale, type AppLocale } from "./dict";

console.log("[boot] main.tsx loaded; mounting React");

window.addEventListener("error", (e) => {
  console.error("[boot] window error:", e.message, e.filename, e.lineno);
});

declare global {
  interface Window {
    __setEditorLocale__?: (code: string) => void;
  }
}

function Shell() {
  const [locale, setLocale] = useState<AppLocale>(() =>
    resolveLocale(navigator.language),
  );

  useEffect(() => {
    // Swift host calls window.editorBridge.setLocale(code) — we expose the
    // setter via a module-level handle so the bridge (set up inside
    // EmbeddedEditor) can forward to us.
    window.__setEditorLocale__ = (code) => setLocale(resolveLocale(code));
    return () => {
      window.__setEditorLocale__ = undefined;
    };
  }, []);

  // key={locale} forces a remount when locale changes: BlockNote reads its
  // dictionary at editor construction, so remount is the supported way to
  // swap languages.
  return <EmbeddedEditor key={locale} locale={locale} />;
}

const root = document.getElementById("root");
if (!root) {
  console.error("[boot] #root not found");
} else {
  ReactDOM.createRoot(root as HTMLElement).render(
    <React.StrictMode>
      <Shell />
    </React.StrictMode>,
  );
  console.log("[boot] React.createRoot().render() called");
}
