# Nixpkgs overlay: patch mautrix-telegram's provisioning webserver so it works
# with aiohttp >= 3.9 (the @web.middleware signature change).
#
# See README.md for the full "why". In short: mautrix-telegram's
# ProvisioningAPI.error_middleware still uses the pre-3.9 aiohttp
# "middleware factory" pattern -- a callable (app, handler) -> coroutine.
# aiohttp 3.9 dropped that mode, and under aiohttp 3.13 the stale factory is
# treated as a plain middleware whose *return value* (a function, not a
# Response) gets handed to finish_response, which then does `.prepare` on a
# function object and raises. Result: every /_matrix/provision/* request 500s.
#
# Usage: add to nixpkgs.overlays, e.g.
#   nixpkgs.overlays = [ (import ./overlays/mautrix-telegram-aiohttp-middleware-fix) ];
#
# (An earlier python3.13 .override pinned the interpreter that shipped the
# affected aiohttp; the default python now ships aiohttp >= 3.9, so the
# override was dropped per the criterion in README.md.)
_final: prev: {
  mautrix-telegram = prev.mautrix-telegram.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ./mautrix-telegram-aiohttp-middleware.patch
    ];
  });
}
