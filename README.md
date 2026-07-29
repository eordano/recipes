# recipes

Reusable, self-contained NixOS/Nix recipes. Each recipe is a directory with the Nix code + a README explaining the *why* and
the traps.

## Documentation site

https://eordano.github.io/recipes

Preview locally:

```sh
# with Nix
nix-shell -p 'python3.withPackages(ps: with ps; [ mkdocs mkdocs-material pymdown-extensions ])' \
  --run 'python3 tools/gen_site.py && mkdocs serve'

# or with pip
pip install -r tools/requirements.txt
python3 tools/gen_site.py && mkdocs serve
```

Then open http://127.0.0.1:8000/recipes/. The generated `site-src/` and built
`site/` are reproducible from the recipes — regenerate rather than editing by hand.

## License

This collection is released into the public domain under the [CC0 1.0
Universal](https://creativecommons.org/publicdomain/zero/1.0/) dedication
(SPDX: `CC0-1.0`). See [`LICENSE`](./LICENSE) for the full legal code. CC0
waives copyright (and related rights) worldwide but does not grant any
patent rights, so it does not by itself protect users from patent claims.
