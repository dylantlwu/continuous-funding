import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Built into the backend's static folder: the Railway service serves the app and its API from one origin.
// In development, /api goes to BACKEND (the deployed service by default, or a local one for a fork run).
export default defineConfig({
  plugins: [react()],
  build: { outDir: "../validation/static/app", emptyOutDir: true },
  server: {
    port: 5173,
    proxy: { "/api": { target: process.env.BACKEND ?? "https://recorder-production-7e4f.up.railway.app", changeOrigin: true } },
  },
});
