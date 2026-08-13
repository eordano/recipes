# spa-nginx-with-streaming-api-origin

A small NixOS module that co-hosts a Nix-built static single-page app **and** a
same-origin streaming API -- Server-Sent Events, a websocket, a chunked
long-poll -- behind **one** nginx vhost. Import it, point it at your built SPA
directory and a set of API path prefixes, and it emits one
`services.nginx.virtualHosts.<name>` that serves the assets, falls back to
`index.html` for client-side routes, and reverse-proxies the API prefixes with
buffering turned off so a stream arrives token by token.

This is the **serving** half. The **build** half -- turning a pnpm/npm workspace
into the static `dist/` directory this module serves -- is
[`packages/js-workspace-package`](../../packages/js-workspace-package/README.md).
Reference it; this recipe does not repeat it.

## The problem

An SPA that talks to a streaming backend wants both halves on the **same
origin**. Split them across two origins (`app.example.com` +
`api.example.com`) and every API call becomes a cross-origin request: you now
own a CORS policy, an `OPTIONS` preflight on anything non-trivial, and a second
certificate. Put them on one origin and all of that evaporates -- the browser
never makes a cross-origin request because, as far as it can tell, there is only
one server.

One origin means one nginx vhost doing two different jobs at once, and the two
jobs fight:

- The SPA half wants a catch-all: **any** path the server doesn't recognise as a
  file should return `index.html`, because the path belongs to the client-side
  router, not to the filesystem. That is a greedy `/` location.
- The API half wants specific path prefixes peeled off **before** that catch-all
  ever sees them, and proxied to a backend -- proxied in a way that does not
  buffer, because the response is a stream that never "finishes" in the sense a
  buffering proxy waits for.

Getting those two to share a server_name without stepping on each other is four
traps deep, and every one of them fails *quietly*: the site loads, the happy
path works, and the thing that's broken (a deep-link reload, a live event feed)
is exactly the thing nobody clicks during setup.

## The approach

One vhost, built from your site definition:

```nix
services.spaStreamingSites."example.com" = {
  root = pkgs.myApp;                    # the built dist/ (js-workspace-package)
  apiUpstreams = {
    "/api/".upstream = "http://127.0.0.1:8080";
    "/sse/".upstream = "http://127.0.0.1:8080";
    "/ws/"  = { upstream = "http://127.0.0.1:8080"; websockets = true; };
  };
  forceSSL = true;
  useACMEHost = "example.com";
};
```

which becomes, in nginx terms:

```nginx
location ^~ /api/ { proxy_pass http://127.0.0.1:8080; <streaming config> }
location ^~ /sse/ { proxy_pass http://127.0.0.1:8080; <streaming config> }
location ^~ /ws/  { proxy_pass http://127.0.0.1:8080; <streaming + upgrade> }
location /       { root /nix/store/...-myApp; try_files $uri /index.html; }
```

Each `apiUpstreams` key becomes a `^~` prefix location carrying the streaming
directives; the SPA is the plain `/` location with the `try_files` fallback. The
four traps below are why each piece is shaped the way it is.

## Trap 1 -- the SPA fallback is `try_files $uri /index.html`

A single-page app owns its own routes. When the user reloads on
`/rooms/42/live`, there is no file at that path -- the route only means something
once the JS bundle has booted and the client-side router reads the URL. So the
server must answer that request with `index.html` (a `200`, the app shell), let
the app boot, and let the router take it from there.

`try_files $uri /index.html` does exactly that: serve the file if it exists on
disk, otherwise serve the entry document. Omit it and a reload on any deep route
is a hard `404` -- the classic "works until you refresh" SPA bug. The module
emits this for you on the `/` location.

## Trap 2 -- the API locations are `^~`, and that prefix is load-bearing

nginx does not evaluate locations top-to-bottom. Its order is: exact `=`, then
`^~` prefixes (longest wins, and a match here **stops** the search), then
**regex** locations in file order, then plain prefixes (longest wins) only if no
regex matched. The trap: **a regex location beats a plain prefix.**

The moment you add a regex location -- and static-asset caching is the most
common reason to (`location ~* \.(js|css|png|woff2)$ { expires 1y; }`) -- a
plain-prefix `/api/` would *lose* to it for any API path the regex happens to
match. Marking the API prefixes `^~` puts them in the tier that wins over regex
and short-circuits the search, so `/api/data.json` is proxied even in the
presence of a `~ \.json$` rule. The module prefixes every `apiUpstreams` key
with `^~` for this reason; the VM test injects a competing `~ \.json$` location
and asserts the API still wins.

(Note that `^~ /api/` beating the plain `/` SPA fallback is *not* the subtle
part -- longest-prefix already does that. `^~` is about beating **regex**
locations, present or future.)

## Trap 3 -- streaming needs buffering off, and long timeouts

By default nginx **buffers** a proxied response: it reads from the upstream into
memory/temp files and only then starts sending to the client. For a normal
request that is a feature. For SSE or a chunked stream it is fatal -- the whole
point is that events reach the browser as they happen, and a buffering proxy
holds every event until the response *ends*, which for a live feed is "never".
The visible symptom is a feed that shows nothing and then dumps everything at
once when the connection finally closes: indistinguishable from a hang.

Each streaming location therefore carries:

```nginx
proxy_http_version 1.1;          # 1.0 has no chunked encoding to frame a stream
proxy_buffering off;             # forward each event as it arrives -- THE line
proxy_request_buffering off;     # don't buffer a streamed/bidirectional upload
proxy_cache off;                 # never cache a stream
gzip off;                        # nginx gzip re-introduces buffering
proxy_read_timeout 1h;           # don't reap an idle-but-live upstream stream
proxy_send_timeout 1h;
send_timeout 1h;                 # ...nor the client side of it
proxy_set_header X-Accel-Buffering no;
```

The timeout is `streamingTimeout` (default `1h`); raise it above the longest gap
you expect between events. There is no "never time out" -- pick a generous
bound. Websocket locations additionally get nginx's `proxyWebsockets` (the
`Upgrade`/`Connection` header dance) when you set `websockets = true`; SSE does
**not** need that, only the buffering-off block. The VM test proves the
difference: the upstream flushes one event then holds the socket open, and a
3-second bounded read returns that event -- which it could not if nginx were
buffering.

## Trap 4 -- the SPA's bundler `base` must be absolute `/`

This one lives in the **build** half but only bites because of the serving
half's fallback, so it belongs here. When Trap 1's fallback serves `index.html`
for a deep route like `/rooms/42/live`, the browser resolves that document's
asset URLs relative to the **page** URL. If the bundle was built with a relative
base (`base: './'`), `index.html` contains `<script src="./assets/app-*.js">`,
which the browser expands to `/rooms/42/assets/app-*.js` -- a path that does not
exist -- and every chunk 404s. The app shell loads and then silently fails to
boot, on deep routes only.

Build with an **absolute** base (`base: '/'`) so the emitted URLs are
`/assets/app-*.js`, which resolve correctly no matter how deep the route that
served the shell was. See `example-vite/vite.config.ts` in this recipe for the
Vite form, including the dev-only proxy that reproduces the same-origin shape
while `vite dev` runs (there is no nginx in front of the dev server, so the same
API prefixes are proxied there instead).

## Usage

```nix
{ pkgs, ... }:
{
  imports = [ ./spa-nginx-with-streaming-api-origin ];

  services.spaStreamingSites."example.com" = {
    # The built SPA directory (index.html + hashed assets). See
    # packages/js-workspace-package for producing it from a JS workspace.
    root = pkgs.myApp;

    apiUpstreams = {
      "/api/".upstream = "http://127.0.0.1:8080";           # plain + streaming JSON
      "/sse/".upstream = "http://127.0.0.1:8080";           # Server-Sent Events
      "/ws/"  = { upstream = "http://127.0.0.1:8080"; websockets = true; };
    };

    streamingTimeout = "1h";
    forceSSL = true;
    useACMEHost = "example.com";   # or enableACME = true; for a per-name cert
  };
}
```

Everything else on the vhost -- TLS, HSTS, real-IP, access logging -- is stock
`services.nginx`; pair this with [`nginx-opinionated-defaults`](../../modules/nginx-opinionated-defaults/README.md)
for those. Reach anything this module doesn't expose through
`extraVirtualHostConfig`, which is merged into the generated vhost (the VM test
uses it to add a competing regex location).

## Options

`services.spaStreamingSites.<name>`:

| Option | Default | Effect |
| --- | --- | --- |
| `serverName` | attr name | The vhost `server_name`. |
| `root` | (required) | The built SPA directory to serve. |
| `index` | `index.html` | The entry document the fallback serves for client-side routes. |
| `apiUpstreams` | `{}` | Map of `<prefix> -> { upstream; websockets; streaming; extraConfig; }`. Each becomes a `^~ <prefix>` location. |
| `streamingTimeout` | `1h` | Read/send/client timeout for streaming locations. |
| `clientMaxBodySize` | `10m` | `client_max_body_size` for the vhost. |
| `forceSSL` / `enableACME` / `useACMEHost` | `false`/`false`/`null` | Passed through to `services.nginx`. |
| `default` | `false` | Make this the default vhost. |
| `extraVirtualHostConfig` | `{}` | Extra attrs merged into the generated vhost. |

Per API upstream (`apiUpstreams.<prefix>.*`):

| Option | Default | Effect |
| --- | --- | --- |
| `upstream` | (required) | `proxy_pass` target, e.g. `http://127.0.0.1:8080`. |
| `websockets` | `false` | Add the websocket upgrade headers (`proxyWebsockets`). |
| `streaming` | `true` | Apply the buffering-off + long-timeout block. Turn off only for a plain buffered JSON endpoint sharing the vhost. |
| `extraConfig` | `""` | Extra directives appended to this location (e.g. an auth-header include). |

## Caveats

- **This module owns the whole vhost's `locations`.** The API prefixes plus the
  `/` fallback are generated; add your own via `extraVirtualHostConfig.locations`
  (they merge). If you need a static-asset caching regex, remember Trap 2 is the
  reason your API prefixes are `^~`.
- **`proxy_pass` here is bare** -- no upstream keepalive pool, no load balancing.
  For multiple backends behind one prefix, define an `upstream {}` block via
  `services.nginx.upstreams` and point `upstream` at it.
- **The backend still has to cooperate.** nginx not buffering does not help if
  your app framework buffers: SSE handlers must flush after each event, and some
  stacks buffer by default. Buffering-off is necessary, not sufficient.
- **`streamingTimeout` is a real ceiling.** A connection idle longer than it is
  cut. For SSE that usually means the client reconnects (EventSource does so
  automatically); for a raw websocket, send application-level pings under the
  bound.

## Related recipes

- [`packages/js-workspace-package`](../../packages/js-workspace-package/README.md)
  -- the build half: the JS workspace that produces the `dist/` this serves.
- [`nginx-opinionated-defaults`](../../modules/nginx-opinionated-defaults/README.md) -- the
  vhost-wide TLS/HSTS/real-IP/logging layer to pair with this.
