import { defineConfig } from 'vite';

// The SERVING half of this recipe (default.nix) serves the built `dist/` with a
// tryFiles $uri /index.html fallback. That fallback is what makes the two
// settings below load-bearing, not cosmetic:
//
//   base: '/'   -- an ABSOLUTE base. When the fallback serves index.html for a
//                  deep route like /rooms/42/live, the browser resolves the
//                  asset URLs in that document relative to the page URL. Under a
//                  relative base ('./'), <script src="./assets/app-*.js"> becomes
//                  /rooms/42/assets/app-*.js and 404s every chunk. With '/', the
//                  same document emits <script src="/assets/app-*.js"> and the
//                  asset resolves regardless of how deep the route was.
//
//   server.proxy -- DEV ONLY. In production the SPA and the API share an origin
//                  because nginx puts them on one vhost; in `vite dev` there is
//                  no nginx, so proxy the same API prefixes to the backend to
//                  reproduce the same-origin shape. `ws: true` also proxies the
//                  websocket upgrade. The prefixes here must match the
//                  `apiUpstreams` keys in the NixOS module.
export default defineConfig({
  base: '/',
  build: { outDir: 'dist', emptyOutDir: true },
  server: {
    proxy: {
      '/api': {
        target: process.env.API_ORIGIN || 'http://localhost:8080',
        changeOrigin: true,
      },
      '/sse': {
        target: process.env.API_ORIGIN || 'http://localhost:8080',
        changeOrigin: true,
      },
      '/ws': {
        target: process.env.API_ORIGIN || 'http://localhost:8080',
        changeOrigin: true,
        ws: true,
      },
    },
  },
});
