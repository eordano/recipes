#!/usr/bin/env python3
"""Generate a MkDocs Material site from the recipe collection.

Each recipe dir (<category>/<name>/{README.md,default.nix}) becomes one page:
the README, rendered as-is, followed by a collapsible "Source" block holding
the default.nix. Category landing pages get a card grid; the home
page gets a hero + category cards. mkdocs.yml (nav + theme) is emitted too.

Pure stdlib. Run from the repo root: python3 tools/gen_site.py
"""
from __future__ import annotations
import re
import shutil
import pathlib
import textwrap

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "site-src"

# category dir -> (nav label, tab icon, one-line blurb for the home card)
CATEGORIES = [
    ("modules", "Modules", "material/puzzle",
     "Importable NixOS modules — services, hardening, setup building blocks."),
    ("behaviors", "Behaviors", "material/timer-cog",
     "Timer- and event-driven system behaviors that maintain state over time."),
    ("overlays", "Overlays", "material/layers-triple",
     "Package-set overlays: upstream fixes, forks, and platform patches."),
    ("packages", "Packages", "material/package-variant-closed",
     "Standalone derivations — CLIs, Python tools, and agenix helpers."),
    ("lib", "Library", "material/function-variant",
     "Small reusable Nix functions and patterns."),
]
CAT_LABEL = {c: lbl for c, lbl, _, _ in CATEGORIES}
RECIPE_CATEGORIES = "|".join(re.escape(cat) for cat, *_ in CATEGORIES)
RECIPE_LINK = re.compile(
    rf"(?P<open>\]\()\.\./\.\./(?P<cat>{RECIPE_CATEGORIES})/"
    r"(?P<name>[^)/#]+)(?:/README\.md)?(?P<fragment>#[^)]*)?(?P<close>\))"
)
LOCAL_NIX_LINK = re.compile(
    r"(?P<open>\]\()\./(?P<file>[^)/#]+\.nix)"
    r"(?P<fragment>#[^)]*)?(?P<close>\))"
)


def slug_dirs(cat: str) -> list[str]:
    d = ROOT / cat
    return sorted(p.name for p in d.iterdir() if p.is_dir() and (p / "README.md").exists())


def read(p: pathlib.Path) -> str:
    return p.read_text(encoding="utf-8")


def title_of(readme: str, fallback: str) -> str:
    m = re.search(r"^#\s+(.+)$", readme, re.MULTILINE)
    return m.group(1).strip() if m else fallback


def summary_of(readme: str) -> str:
    """First real paragraph after the H1, flattened to one line."""
    body = re.sub(r"^#\s+.+$", "", readme, count=1, flags=re.MULTILINE).strip()
    para = ""
    for block in re.split(r"\n\s*\n", body):
        b = block.strip()
        if not b or b.startswith(("#", "```", "|", "-", "*", ">")):
            continue
        para = b
        break
    para = re.sub(r"\s+", " ", para)
    para = re.sub(r"\*\*(.+?)\*\*", r"\1", para)
    para = re.sub(r"\*(.+?)\*", r"\1", para)
    para = re.sub(r"`(.+?)`", r"\1", para)
    if len(para) > 180:
        # Prefer the *last* sentence boundary at or before the limit, so a short
        # opening sentence ("It works. <the actual explanation>") doesn't shrink
        # the blurb to three words. Only take it if enough text survives to be
        # useful; otherwise fall back to a word boundary plus an ellipsis.
        ends = [m.end() for m in re.finditer(r"[.?!](?=\s|$)", para[:180])]
        if ends and ends[-1] >= 90:
            # Ends on a complete sentence — no ellipsis, it already reads whole.
            para = para[: ends[-1]].rstrip()
        else:
            cut = para[:180].rsplit(" ", 1)[0]
            # Drop trailing punctuation that reads as incomplete before the "…".
            para = cut.rstrip(":,;—-").rstrip() + "…"
    else:
        # Even short paragraphs may end with a colon / comma that precedes a
        # list in the original markdown — strip those so the blurb reads cleanly.
        para = para.rstrip(":,;—-").rstrip()
    return para or "A reusable Nix recipe."


def rewrite_links_for_site(markdown: str, cat: str, name: str) -> str:
    """Translate repository-relative links for generated MkDocs pages.

    Recipe pages move from ``<cat>/<name>/README.md`` to
    ``site-src/<cat>/<name>.md``. Cross-recipe links therefore lose one path
    component. Links to sibling Nix files have no generated page, so keep them
    useful by pointing at the public repository source.
    """

    def recipe_target(match: re.Match[str]) -> str:
        fragment = match.group("fragment") or ""
        return (
            f"{match.group('open')}../{match.group('cat')}/"
            f"{match.group('name')}.md{fragment}{match.group('close')}"
        )

    def nix_target(match: re.Match[str]) -> str:
        fragment = match.group("fragment") or ""
        return (
            f"{match.group('open')}https://github.com/eordano/recipes/blob/main/"
            f"{cat}/{name}/{match.group('file')}{fragment}{match.group('close')}"
        )

    markdown = RECIPE_LINK.sub(recipe_target, markdown)
    return LOCAL_NIX_LINK.sub(nix_target, markdown)


def recipe_page(cat: str, name: str) -> tuple[str, str, str]:
    """Return (title, summary, page_markdown) for one recipe."""
    d = ROOT / cat / name
    readme = rewrite_links_for_site(read(d / "README.md"), cat, name)
    code = read(d / "default.nix").rstrip("\n")
    title = title_of(readme, name)
    summary = summary_of(readme)

    # A small metadata line under the H1: category chip + source jump.
    chip = f"`{CAT_LABEL[cat]}`"
    header, _, rest = readme.partition("\n")
    body = header + f"\n\n<span class=\"recipe-cat\">{chip}</span>\n" + rest

    # Collapsible source, inside a `??? note` admonition. Everything in the
    # admonition body — the fence markers and the code — must sit at the same
    # 4-space indent, or superfences won't close the block correctly.
    src = (
        "\n\n## Source\n\n"
        f'??? note "`{cat}/{name}/default.nix`"\n\n'
        "    ```nix\n"
        + textwrap.indent(code, "    ")
        + "\n    ```\n"
    )

    return title, summary, body.rstrip("\n") + "\n" + src


def card(href: str, title: str, summary: str, icon: str | None = None) -> str:
    ic = f":{icon.replace('/', '-')}:{{ .lg .middle }} " if icon else ""
    return (f"-   {ic}__[{title}]({href})__\n\n"
            f"    ---\n\n"
            f"    {summary}\n")


def write(path: pathlib.Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def main() -> None:
    if SRC.exists():
        shutil.rmtree(SRC)
    SRC.mkdir(parents=True, exist_ok=True)
    # static assets live under tools/assets and are copied in fresh each run
    shutil.copytree(ROOT / "tools" / "assets", SRC / "assets")

    nav = ["  - Home: index.md"]
    counts = {}
    home_summaries = {}  # cat -> list of (title, href, summary) for later

    for cat, label, icon, blurb in CATEGORIES:
        names = slug_dirs(cat)
        counts[cat] = len(names)
        cards = []
        nav.append(f"  - {label}:")
        nav.append(f"      - Overview: {cat}/index.md")
        entries = []
        for name in names:
            title, summary, page = recipe_page(cat, name)
            write(SRC / cat / f"{name}.md", page)
            q = title.replace('"', '\\"')
            nav.append(f'      - "{q}": {cat}/{name}.md')
            cards.append(card(f"{name}.md", title, summary))
            entries.append((title, name, summary))
        # category overview page. NOTE: the card grid is inserted via a
        # single-line placeholder AFTER dedent — interpolating a multi-line
        # (column-0) block directly would defeat textwrap.dedent and leave the
        # whole page indented, which Markdown renders as one big code block.
        grid = "<div class=\"grid cards\" markdown>\n\n" + "\n".join(cards) + "\n</div>\n"
        page = textwrap.dedent(f"""\
            # {label}

            {blurb}

            <span class="count-pill">{len(names)} recipes</span>

            __GRID__
            """).replace("__GRID__", grid)
        write(SRC / cat / "index.md", page)
        home_summaries[cat] = entries

    # ---- home page ----
    total = sum(counts.values())
    cat_cards = []
    for cat, label, icon, blurb in CATEGORIES:
        cat_cards.append(card(f"{cat}/index.md", f"{label} · {counts[cat]}", blurb, icon))
    cat_grid = "<div class=\"grid cards\" markdown>\n\n" + "\n".join(cat_cards) + "\n</div>\n"

    home = textwrap.dedent(f"""\
        ---
        hide:
          - navigation
          - toc
        ---

        <div class="hero" markdown>

        # Nix Recipes

        ### Recipes for NixOS and nix-darwin

        Each recipe is a self-contained module, overlay, or package paired with a
        **why-and-trap** writeup: not just what the code does, but the failure it
        prevents and the sharp edge that made it necessary. No hostnames, addresses,
        or secrets — drop any recipe straight into your own configuration.

        [Browse the recipes :material-arrow-right:](modules/index.md){{ .md-button .md-button--primary }}
        [How it's organized :material-book-open-variant:](#how-its-organized){{ .md-button }}

        </div>

        ## Categories

        __CATGRID__

        ## How it's organized {{ #how-its-organized }}

        Recipes fall into five families. Everything is a Nix flake output, so a recipe
        is `nix flake`-consumable directly:

        ```nix
        {{
          inputs.recipes.url = "github:eordano/recipes";
          # ... then, in a host:
          imports = [ inputs.recipes.nixosModules.nixos-hardening-tiers ];
          nixpkgs.overlays = [ inputs.recipes.overlays.caddy-override-keep-withplugins ];
        }}
        ```

        - **Modules** — importable `nixosModules.<name>`; opt-in via their own options.
        - **Behaviors** — modules too, but timer/event-driven ones that *maintain* state.
        - **Overlays** — `overlays.<name>`; upstream fixes, forks, platform patches.
        - **Packages** — `pkgs.callPackage ./packages/<name> {{ }}` derivations.
        - **Library** — small reusable Nix functions.
        """).replace("__CATGRID__", cat_grid)
    write(SRC / "index.md", home)

    # ---- mkdocs.yml ----
    nav_yaml = "\n".join(nav)
    mkdocs = textwrap.dedent(f"""\
        site_name: Nix Recipes
        site_description: >-
          {total} reusable recipes for NixOS and nix-darwin systems — modules,
          overlays, and packages — each with a why-and-trap writeup.
        site_url: https://eordano.github.io/recipes/
        repo_url: https://github.com/eordano/recipes
        repo_name: eordano/recipes
        edit_uri: ""
        docs_dir: site-src
        site_dir: site

        validation:
          omitted_files: warn
          absolute_links: warn
          unrecognized_links: warn
          anchors: warn
          links:
            not_found: warn

        copyright: >-
          Released into the public domain under
          <a href="https://creativecommons.org/publicdomain/zero/1.0/">CC0 1.0 Universal</a>.

        theme:
          name: material
          palette:
            - media: "(prefers-color-scheme: light)"
              scheme: default
              primary: indigo
              accent: indigo
              toggle:
                icon: material/weather-night
                name: Switch to dark mode
            - media: "(prefers-color-scheme: dark)"
              scheme: slate
              primary: indigo
              accent: indigo
              toggle:
                icon: material/weather-sunny
                name: Switch to light mode
          font:
            text: Inter
            code: JetBrains Mono
          icon:
            repo: fontawesome/brands/github
          features:
            - navigation.tabs
            - navigation.tabs.sticky
            - navigation.sections
            - navigation.top
            - navigation.footer
            - navigation.indexes
            - search.suggest
            - search.highlight
            - search.share
            - toc.follow
            - content.code.copy
            - content.code.annotate

        extra_css:
          - assets/extra.css

        markdown_extensions:
          - admonition
          - attr_list
          - md_in_html
          - tables
          - footnotes
          - toc:
              permalink: true
          - pymdownx.details
          - pymdownx.superfences
          - pymdownx.highlight:
              anchor_linenums: true
              line_spans: __span
              pygments_lang_class: true
          - pymdownx.inlinehilite
          - pymdownx.snippets
          - pymdownx.emoji:
              emoji_index: !!python/name:material.extensions.emoji.twemoji
              emoji_generator: !!python/name:material.extensions.emoji.to_svg
          - pymdownx.tabbed:
              alternate_style: true

        plugins:
          - search

        extra:
          social:
            - icon: fontawesome/brands/github
              link: https://github.com/eordano/recipes
          generator: false

        nav:
        """)
    # nav_yaml is multi-line with its own indentation; appending after dedent
    # avoids textwrap.dedent collapsing the template's common prefix to zero.
    write(ROOT / "mkdocs.yml", mkdocs + nav_yaml + "\n")

    print(f"Generated site-src/ for {total} recipes across {len(CATEGORIES)} categories:")
    for cat, label, *_ in CATEGORIES:
        print(f"  {label:10s} {counts[cat]:3d}")
    print(f"mkdocs.yml written with {len(nav)} nav lines.")


if __name__ == "__main__":
    main()
