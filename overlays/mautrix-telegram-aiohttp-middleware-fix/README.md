# Fix mautrix-telegram Provisioning API Breakage on aiohttp 3.9+

A nixpkgs overlay that patches [mautrix-telegram](https://github.com/mautrix/telegram)'s
provisioning webserver so it survives **aiohttp 3.9+**.

## The problem

Point a recent nixpkgs (one that builds mautrix-telegram against aiohttp 3.9
or newer — 3.13 in particular) at the Telegram bridge and every request to
`/_matrix/provision/*` returns **HTTP 500** with:

```
AttributeError: 'function' object has no attribute 'prepare'
```

This is not limited to error paths. Middleware runs *before* the route
handler, so the handler is never reached — the whole provisioning API is dead.

## The trap

mautrix-telegram's `ProvisioningAPI.error_middleware` was written in aiohttp's
**old "middleware factory" style**: a callable

```python
async def error_middleware(app, handler):        # (app, handler) -> coroutine
    async def middleware_handler(request):
        ...
    return middleware_handler                     # returns a *function*
```

aiohttp 3.9 **removed** the factory mode. Middlewares are now plain
`(request, handler) -> Response` coroutines decorated with `@web.middleware`.

The insidious part: aiohttp doesn't reject the stale factory. It treats it as
an ordinary middleware and calls it with `(request, handler)`. The factory
then *returns* its inner `middleware_handler` **function** instead of a
`Response`. aiohttp passes that return value straight to `finish_response`,
which calls `.prepare()` on it — and a function object has no `.prepare`. Hence
the cryptic `AttributeError` on every request rather than a clear "bad
middleware signature" error.

## The fix

Rewrite the middleware to the modern signature: decorate it with
`@web.middleware`, take `(request, handler)` directly, and `return` a
`Response` (or re-raise) inline instead of returning a nested handler
function. The patch in this recipe does exactly that.

## Usage

Add the overlay to your nixpkgs config:

```nix
{
  nixpkgs.overlays = [
    (import ./overlays/mautrix-telegram-aiohttp-middleware-fix)
  ];
}
```

or apply it directly when you import nixpkgs:

```nix
import nixpkgs {
  inherit system;
  overlays = [ (import ./overlays/mautrix-telegram-aiohttp-middleware-fix) ];
}
```

The directory contains:

- `default.nix` — the overlay (`overrideAttrs` appends the patch).
- `mautrix-telegram-aiohttp-middleware.patch` — the actual source fix.

## Caveats

- **Line offsets.** The patch targets
  `mautrix_telegram/web/provisioning/__init__.py` around the `@staticmethod`
  `error_middleware`. If your mautrix-telegram version has shifted those lines,
  regenerate the patch against your pinned source — the transformation is
  trivial (add `@web.middleware`, flatten the factory into a
  `(request, handler) -> Response` coroutine).
- **The python3.13 override is optional.** `default.nix` pins the interpreter
  that pulls in an affected aiohttp so the bug is reproducible. Drop the
  `.override { python3 = prev.python313; }` if your nixpkgs already builds the
  bridge against aiohttp ≥ 3.9 on its default interpreter.
- **Upstream may fix this.** Once mautrix-telegram ships the modern middleware
  signature, drop the overlay entirely.
