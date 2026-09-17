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
    hash = "sha256-awBkr2ObRxPQkMlfVFZxEbQ9JQJsFrJvSBHtqP4Hb3I=";
  };

  vendorHash = "sha256-TzVmAMrNrNkFE9jQ+SILJXvbhBK1WenNPqA0FfuDU+M=";

  subPackages = [ "cmd/bbolt" ];

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
