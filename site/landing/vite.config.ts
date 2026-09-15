import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  // Served from openbeam.manuelvega.dev, so the landing page is the root. The
  // docs are a separate build that lands at /docs/.
  base: '/',
})
