import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  // Served from a GitHub project page. The docs site is a separate build that
  // lands at /OpenBeam/docs/.
  base: '/OpenBeam/',
})
