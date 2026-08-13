# flake-systems-that-exist
#
# Derive a flake's `systems` list from what the PINNED nixpkgs actually
# supports, instead of hardcoding it and letting it go stale.
#
# A hardcoded system that the pinned nixpkgs has dropped is not "an output that
# is missing" -- `import nixpkgs { system = <dropped>; }` throws
# (pkgs/top-level/default.nix), so every output generated for that system
# becomes an evaluation ERROR. Plain `nix flake check` never evaluates it,
# because it only checks systems the host can build.
#
#   sys = import ./lib/flake-systems-that-exist {
#     inherit (nixpkgs) lib;
#     want = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
#   };
#   # sys.systems  == the subset this nixpkgs still supports
#   # sys.dropped  == [ "x86_64-darwin" ]  (real double, no longer supported)
#   packages = sys.forAllSystems (system: ...);
#
# See README.md for the detection command and why the two classes of bad entry
# are treated differently.

{
  # `lib` from the SAME nixpkgs the flake's outputs are built against. Taking it
  # from anywhere else reintroduces the staleness this exists to remove.
  lib,

  # Desired systems. `null` means "every system this nixpkgs supports".
  want ? null,

  # Throw on entries that are not system doubles at all (typos). Intersection
  # alone would silently discard them, which is the same class of bug.
  strict ? true,

  # Emit an eval-time warning naming entries that are real doubles but no longer
  # supported, so the stale entry gets deleted rather than quietly ignored.
  warnDropped ? true,
}:
let
  inherit (builtins)
    concatStringsSep
    deepSeq
    elem
    filter
    tryEval
    ;

  # The authoritative list: what this nixpkgs says a flake should expose.
  supported = lib.systems.flakeExposed;

  # A dropped system is still a parseable double; a typo is not. That is the
  # only signal available from the pinned tree, and it is enough to separate
  # "delete this stale entry" from "you misspelled this".
  isDouble = s: (tryEval (deepSeq (lib.systems.parse.mkSystemFromString s) true)).success;

  requested = if want == null then supported else want;

  typos = filter (s: !isDouble s) requested;
  dropped = filter (s: isDouble s && !elem s supported) requested;
  kept = filter (s: elem s supported) requested;

  fail = msg: throw "flake-systems-that-exist: ${msg}";

  systems =
    if strict && typos != [ ] then
      fail (
        "not system doubles: ${concatStringsSep ", " typos}. "
        + "These would be silently dropped, so the flake would build nothing for them and stay green."
      )
    else if kept == [ ] then
      fail (
        "none of the requested systems are supported by the pinned nixpkgs "
        + "(requested: ${concatStringsSep ", " requested}). A flake with an empty system list "
        + "produces no outputs and passes every check."
      )
    else if warnDropped && dropped != [ ] then
      lib.warn (
        "flake-systems-that-exist: the pinned nixpkgs no longer supports "
        + "${concatStringsSep ", " dropped}; dropped from the system list. Delete the entry."
      ) kept
    else
      kept;
in
{
  inherit
    systems
    supported
    dropped
    typos
    ;

  # f :: system-string -> a
  forAllSystems = f: lib.genAttrs systems f;
}
