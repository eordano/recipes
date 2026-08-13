# Add a runtime/build dependency that the pinned nixpkgs revision omits.
#
# Use `pyfinal` (self) for the injected deps so they resolve against the final,
# fully-patched package set rather than the pre-override one.
_topPrev: pyfinal: pyprev: {
  example-underdeclared = pyprev.example-underdeclared.overridePythonAttrs (old: {
    build-system = (old.build-system or [ ]) ++ [ pyfinal.hatchling ];
    dependencies = (old.dependencies or [ ]) ++ [
      pyfinal.markdown-it-py
      pyfinal.mdit-py-plugins
    ];
  });
}
