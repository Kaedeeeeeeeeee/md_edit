import React from "react";
import ReactDOM from "react-dom/client";
import { EmbeddedEditor } from "./EmbeddedEditor";

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <EmbeddedEditor />
  </React.StrictMode>,
);
