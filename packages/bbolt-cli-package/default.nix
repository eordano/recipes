{
  lib,
  buildGoLatestModule,
  fetchFromGitHub,
}:
buildGoLatestModule rec {
  pname = "bbolt-cli";
  version = "1.5.0";

  src = fetchFromGitHub {
    owner = "etcd-io";
    repo = "bbolt";
    rev = "v${version}";
    hash = "sha256-y48QXeffXBNBEsScMTSWQnXVG7xCZEAbAGKyfzl9m4Q=";
  };

  vendorHash = "sha256-Tp6IINFK8SR2AIqEeMP3qK2f90EpLPMibFATG3j9VKs=";

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
