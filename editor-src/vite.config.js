import { defineConfig } from 'vite'
import { viteSingleFile } from 'vite-plugin-singlefile'

export default defineConfig({
  plugins: [viteSingleFile()],
  build: {
    outDir: '../BlobTxt/Resources',
    emptyOutDir: false,
    rollupOptions: {
      input: 'editor.html',
    },
  },
})
