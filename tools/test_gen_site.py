#!/usr/bin/env python3

import unittest
import contextlib
import io
import os
import pathlib
import shutil
import tempfile
from unittest import mock
import gen_site

from gen_site import rewrite_links_for_site


class RewriteLinksForSiteTests(unittest.TestCase):
    def test_rewrites_cross_recipe_directory_link(self):
        markdown = "[topology](../../lib/nixos-test-topology)"
        self.assertEqual(
            rewrite_links_for_site(markdown, "modules", "example"),
            "[topology](../lib/nixos-test-topology.md)",
        )

    def test_rewrites_cross_recipe_readme_and_preserves_fragment(self):
        markdown = "[topology](../../lib/nixos-test-topology/README.md#trap-4)"
        self.assertEqual(
            rewrite_links_for_site(markdown, "modules", "example"),
            "[topology](../lib/nixos-test-topology.md#trap-4)",
        )

    def test_rewrites_sibling_nix_link_to_public_source(self):
        markdown = "[VM test](./test.nix)"
        self.assertEqual(
            rewrite_links_for_site(markdown, "modules", "mirrored-esp"),
            (
                "[VM test](https://github.com/eordano/recipes/blob/main/"
                "modules/mirrored-esp/test.nix)"
            ),
        )

    def test_leaves_external_and_unrelated_links_unchanged(self):
        markdown = "[site](https://example.com) [section](#section)"
        self.assertEqual(
            rewrite_links_for_site(markdown, "modules", "example"),
            markdown,
        )


class IncrementalGenerationTests(unittest.TestCase):
    def test_preserves_unchanged_outputs_and_removes_obsolete_pages(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for cat, *_ in gen_site.CATEGORIES:
                (root / cat).mkdir()
            recipe = root / "modules" / "example"
            recipe.mkdir()
            (recipe / "README.md").write_text("# Example\n\nDescription.\n")
            (recipe / "default.nix").write_text("{}\n")
            assets = root / "tools" / "assets"
            assets.mkdir(parents=True)
            (assets / "style.css").write_text("body {}\n")
            with mock.patch.object(gen_site, "ROOT", root), mock.patch.object(gen_site, "SRC", root / "site-src"), contextlib.redirect_stdout(io.StringIO()):
                gen_site.main()
                outputs = [p for p in root.rglob("*") if p.is_file() and ("site-src" in p.parts or p.name == "mkdocs.yml")]
                for path in outputs:
                    os.utime(path, ns=(1_000_000_000, 1_000_000_000))
                gen_site.main()
                self.assertTrue(all(p.stat().st_mtime_ns == 1_000_000_000 for p in outputs))
                (recipe / "default.nix").write_text("{ enabled = true; }\n")
                gen_site.main()
                page = root / "site-src/modules/example.md"
                self.assertIn("enabled = true", page.read_text())
                self.assertEqual((root / "site-src/assets/style.css").stat().st_mtime_ns, 1_000_000_000)
                (assets / "style.css").unlink()
                (assets / "style.css").mkdir()
                (assets / "style.css/nested.css").write_text("body { color: red; }\n")
                gen_site.main()
                self.assertEqual((root / "site-src/assets/style.css/nested.css").read_text(), "body { color: red; }\n")
                shutil.rmtree(assets / "style.css")
                (assets / "style.css").write_text("body { color: blue; }\n")
                gen_site.main()
                self.assertEqual((root / "site-src/assets/style.css").read_text(), "body { color: blue; }\n")
                (recipe / "README.md").unlink()
                (assets / "style.css").unlink()
                gen_site.main()
                self.assertFalse(page.exists())
                self.assertFalse((root / "site-src/assets/style.css").exists())


if __name__ == "__main__":
    unittest.main()
