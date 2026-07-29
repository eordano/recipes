#!/usr/bin/env python3

import unittest

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


if __name__ == "__main__":
    unittest.main()
