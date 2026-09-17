{
  lib,

  want ? null,

  strict ? true,

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

  supported = lib.systems.flakeExposed;

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

  forAllSystems = f: lib.genAttrs systems f;
}
