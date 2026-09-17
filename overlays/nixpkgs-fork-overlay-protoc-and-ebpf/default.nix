{
  forkSrc,

  version,

  vendorHash,

  pname ? "opensnitch",
  uiPname ? "opensnitch-ui",
  ebpfPname ? "opensnitch-ebpf",

  protocOutputDirs ? [
    "daemon/ui/protocol"
    "ui/opensnitch/proto"
  ],

  uiSubdir ? "ui",

  doCheck ? false,
}:

_final: prev:

let
  namedSrc = prev.runCommand "${pname}-${version}-source" { } ''
    cp -r ${forkSrc.outPath or forkSrc} $out
    chmod -R u+w $out
    mkdir -p ${prev.lib.concatMapStringsSep " " (d: "$out/${d}") protocOutputDirs}
  '';

  dropEbpfPatches = _lpFinal: lpPrev: {
    ${ebpfPname} = lpPrev.${ebpfPname}.overrideAttrs { patches = [ ]; };
  };
in
{
  ${pname} = prev.${pname}.overrideAttrs (old: {
    inherit version doCheck;
    src = namedSrc;
    patches = [ ];
    goModules = old.goModules.overrideAttrs {
      inherit vendorHash;
      src = namedSrc;
    };
  });

  ${uiPname} = prev.${uiPname}.overrideAttrs (_old: {
    inherit version;
    src = namedSrc;
    sourceRoot = "${namedSrc.name}/${uiSubdir}";
    patches = [ ];
  });

  linuxKernel = prev.linuxKernel // {
    packagesFor = kernel: (prev.linuxKernel.packagesFor kernel).extend dropEbpfPatches;
  };
}
