_final: prev:

let
  patchVendoredGoDep =
    {
      patch,
      module,
      subpath,
      vendorDir ? "vendor",
    }:
    ''
      # 1. The Go fetcher's vendor tree is read-only; make the touched subtree writable.
      chmod -R +w ${vendorDir}/${module}/${subpath}

      # 2. Rewrite a//b/ prefixes to the vendored module layout, then apply.
      #    -p1 strips the leading a//b/ so paths resolve under ${vendorDir}/.
      sed 's|a/${subpath}|a/${module}/${subpath}|g;s|b/${subpath}|b/${module}/${subpath}|g' \
        ${patch} | patch -d ${vendorDir} -p1
    '';
in
{
  example-go-package = prev.example-go-package.overrideAttrs (_old: {
    buildPhase = ''
      # (env such as GOOS/GOARCH goes here if you cross-compile, e.g. wasm)

      if [ -f patches/my-upstream-fix.patch ]; then
        ${patchVendoredGoDep {
          patch = "patches/my-upstream-fix.patch";
          module = "example.com/somedep";
          subpath = "internal/thing/";
        }}
      fi

      go build -mod=vendor -o out ./cmd/tool
    '';
  });

  inherit patchVendoredGoDep;
}
