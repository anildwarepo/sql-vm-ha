import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

const api = process.env.SQLHA_API_URL ?? 'http://127.0.0.1:8000'

// The dev server proxies /api to the FastAPI backend, so the browser talks to one origin.
export default defineConfig({
  plugins: [react()],
  server: {
    host: '127.0.0.1',
    port: Number(process.env.SQLHA_UI_PORT ?? 5173),
    strictPort: true,
    proxy: {
      '/api': { target: api, changeOrigin: false },
      '/docs': { target: api },
      '/openapi.json': { target: api },
    },
  },
  build: { outDir: 'dist', sourcemap: true },
})
