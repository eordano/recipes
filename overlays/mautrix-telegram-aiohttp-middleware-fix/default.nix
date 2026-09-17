_final: prev: {
  mautrix-telegram = prev.mautrix-telegram.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ./mautrix-telegram-aiohttp-middleware.patch
    ];
  });
}
