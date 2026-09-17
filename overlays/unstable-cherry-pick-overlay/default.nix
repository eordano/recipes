{
  unstable,

  zig ? null,
}:
_final: prev:
{
  aider-chat = unstable.aider-chat.overridePythonAttrs (old: {
    disabledTests = (old.disabledTests or [ ]) ++ [
      "test_max_context_tokens"
      "test_cmd_read_only_with_image_file"
      "test_cmd_tokens_output"
    ];
  });

  ghostty = unstable.ghostty.overrideAttrs (_: {
    doCheck = false;
  });

  inherit (unstable)
    atuin
    neovim
    ;

  marimo = unstable.marimo.overridePythonAttrs (old: {
    patches = builtins.filter (p: !(p ? name && p.name == "uv-build.patch")) (old.patches or [ ]);
    build-system = (old.build-system or [ ]) ++ [ unstable.python3Packages.uv-build ];
    dependencies = (old.dependencies or [ ]) ++ [ unstable.python3Packages.msgspec ];
    pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "jedi" ];
    postPatch = (old.postPatch or "") + ''
      substituteInPlace pyproject.toml \
        --replace-quiet 'uv_build>=0.8.3,<0.12.0' 'uv_build>=0.8.3'
    '';
  });
}
// prev.lib.optionalAttrs (zig != null) {
  zig = zig.packages.${prev.stdenv.hostPlatform.system}.master;
}
