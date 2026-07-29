# fish 4.8 stopped shipping share/fish/tools/ on disk — the manpage-completions
# generator (create_manpage_completions.py) is now embedded in the fish binary.
# home-manager's fish module still invokes
#   ${fish}/share/fish/tools/create_manpage_completions.py
# for programs.fish generateCompletions, so every *-fish-completions derivation
# fails to build against fish 4.8+.
#
# This overlay re-materializes the script from the binary via `status get-file`
# (the same mechanism home-manager master uses to extract it). Drop the overlay
# once your home-manager input carries that fix.
#
# Usage — add to nixpkgs.overlays:
#   nixpkgs.overlays = [ (import ./fish-manpage-completions-fix) ];
#
# or with flakes:
#   pkgs = import nixpkgs { overlays = [ (import ./fish-manpage-completions-fix) ]; };
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
