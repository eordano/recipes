# Extract ONE command from a multi-command Go module.
#
# etcd-io/bbolt is a library repo that also ships several commands under cmd/.
# We only want the `bbolt` CLI (inspect/edit BoltDB files), not the whole tree.
#
# The reusable trick: `subPackages = [ "cmd/bbolt" ]` tells buildGoModule to
# compile and install exactly that one package instead of every main package in
# the module. `ldflags = [ "-s" "-w" ]` strips the symbol table and DWARF debug
# info from the resulting binary.
#
# Build with, e.g.:
#   pkgs.callPackage ./default.nix { }
{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule rec {
  pname = "bbolt-cli";
  version = "1.4.3";

  src = fetchFromGitHub {
    owner = "etcd-io";
    repo = "bbolt";
    rev = "v${version}";
    # nix-prefetch or the first failing build prints the correct hash.
    hash = "sha256-awBkr2ObRxPQkMlfVFZxEbQ9JQJsFrJvSBHtqP4Hb3I=";
  };

  # Hash of the vendored Go dependencies. Set to lib.fakeHash on first build,
  # then paste the value Nix reports.
  vendorHash = "sha256-TzVmAMrNrNkFE9jQ+SILJXvbhBK1WenNPqA0FfuDU+M=";

  # THE KEY LINE: build only cmd/bbolt, not every command in the repo.
  # Paths are relative to the module root (where go.mod lives).
  subPackages = [ "cmd/bbolt" ];

  # -s strips the symbol table, -w drops DWARF debug info: smaller binary.
  ldflags = [
    "-s"
    "-w"
  ];

  meta = {
    description = "BoltDB CLI tool for inspecting and manipulating bbolt databases";
    homepage = "https://github.com/etcd-io/bbolt";
    license = lib.licenses.mit;
    mainProgram = "bbolt";
  };
}
