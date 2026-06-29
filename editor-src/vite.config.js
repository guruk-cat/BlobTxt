import { defineConfig } from 'vite'
import { viteSingleFile } from 'vite-plugin-singlefile'

export default defineConfig({
  plugins: [viteSingleFile()],
  build: {
    outDir: '../BlobTxt/Resources',
    emptyOutDir: false,
    // Inline every asset (incl. KaTeX's woff2/woff/ttf fonts) as base64 so the
    // single-file editor.html keeps no external file deps in the WKWebView.
    // Inlines all 3 font formats (~1.1M); woff2-only (~300K) is theupgrade 
    // path if bundle size matters (needs the katex CSS src lists trimmed).
    assetsInlineLimit: 100000000,
    rollupOptions: {
      input: 'editor.html',
    },
  },
})
