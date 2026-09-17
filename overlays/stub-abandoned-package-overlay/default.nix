{
  name,
  subAttrs ? { },
}:

_final: prev:

let
  emptyDrv =
    drvName: dirs:
    prev.runCommand drvName { } (
      if dirs == [ ] then
        "mkdir -p $out"
      else
        "mkdir -p " + prev.lib.concatMapStringsSep " " (d: "$out/" + d) dirs
    );

  subDrvs = prev.lib.mapAttrs (attr: dirs: emptyDrv "${name}-${attr}-stub" dirs) subAttrs;
in
{
  ${name} = emptyDrv "${name}-stub" [ ] // subDrvs;
}
