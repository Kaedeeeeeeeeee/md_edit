import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

// File-protocol friendly: relative URLs, single bundle, write directly into the
// macOS app's Resources/editor directory so xcodebuild picks it up.
export default defineConfig({
  plugins: [react()],
  base: "./",
  build: {
    outDir: resolve(__dirname, "../Resources/editor"),
    emptyOutDir: true,
    assetsDir: "assets",
    target: "es2022",
  },
});
