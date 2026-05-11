import React from "react";
import ReactDOM from "react-dom/client";
import { EmbeddedEditor } from "./EmbeddedEditor";

console.log("[boot] main.tsx loaded; mounting React");

window.addEventListener("error", (e) => {
  console.error("[boot] window error:", e.message, e.filename, e.lineno);
});

const root = document.getElementById("root");
if (!root) {
  console.error("[boot] #root not found");
} else {
  ReactDOM.createRoot(root as HTMLElement).render(
    <React.StrictMode>
      <EmbeddedEditor />
    </React.StrictMode>,
  );
  console.log("[boot] React.createRoot().render() called");
}
