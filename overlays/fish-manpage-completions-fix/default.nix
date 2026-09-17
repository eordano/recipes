_: prev: {
  fish = prev.fish.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      if [ ! -e $out/share/fish/tools/create_manpage_completions.py ]; then
        mkdir -p $out/share/fish/tools
        $out/bin/fish --no-config \
          -c 'status get-file tools/create_manpage_completions.py' \
          > $out/share/fish/tools/create_manpage_completions.py
      fi
    '';
  });
}
