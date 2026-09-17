_final: prev:

let
  chantools = prev.callPackage (
    {
      lib,
      buildGoModule,
      fetchFromGitHub,
    }:
    buildGoModule rec {
      pname = "chantools";
      version = "0.14.2";

      src = fetchFromGitHub {
        owner = "lightninglabs";
        repo = "chantools";
        rev = "v${version}";
        hash = "sha256-pHcTBoipN1mYdGPswgAUVs/A3k1HKD5LXmCxwduStOw=";
      };

      vendorHash = "sha256-+jOrR8jhNdMvICwwLPAuYTGjlkXh7y4tZceioi9EJQI=";

      subPackages = [ "cmd/chantools" ];

      ldflags = [
        "-s"
        "-w"
      ];

      checkFlags = [ "-skip=^TestCompactDBAndDumpChannels$" ];

      meta = {
        description = "Tools for rescuing funds from Lightning Network channels";
        homepage = "https://github.com/lightninglabs/chantools";
        license = lib.licenses.mit;
        mainProgram = "chantools";
      };
    }
  ) { };

  bbolt-cli = prev.callPackage (
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
  ) { };
in
{
  inherit chantools bbolt-cli;
}
