import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import fs from 'node:fs'
import path from 'node:path'

// The viewer is served from batches.space/app/, and Vercel also sends /b/<id> (the links the iPhone
// app shares) to it; see site/vercel.json. The build goes straight into site/app/.
const site = path.resolve(__dirname, '../site')

/** Locally, do what Vercel does: /b/* and /app/* get the viewer, and the site's images are there. */
function likeVercel() {
  const handle = (req, _res, next) => {
    const url = req.url ?? '/'
    if (/^\/b\/[^/?]+\/?(\?|$)/.test(url) || /^\/app\/?(friends|people|u\/[^/?]+)?\/?(\?|$)/.test(url)) req.url = '/app/' + (url.split('?')[1] ? '?' + url.split('?')[1] : '')
    else if (/^\/(img\/|favicon\.png|apple-touch-icon\.png)/.test(url)) {
      const file = path.join(site, url.split('?')[0])
      if (file.startsWith(site) && fs.existsSync(file)) return fs.createReadStream(file).pipe(_res)
    }
    next()
  }
  return {
    name: 'like-vercel',
    configureServer: (server) => { server.middlewares.use(handle) },
    configurePreviewServer: (server) => { server.middlewares.use(handle) },
  }
}

export default defineConfig({
  base: '/app/',
  plugins: [likeVercel(), react()],
  build: { outDir: path.join(site, 'app'), emptyOutDir: true, chunkSizeWarningLimit: 2500 },
  worker: { format: 'es' },
})
