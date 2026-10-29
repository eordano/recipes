_final: prev:

let
  chantools = prev.callPackage (
    {
      lib,
      buildGoLatestModule,
      fetchFromGitHub,
    }:
    buildGoLatestModule rec {
      pname = "chantools";
      version = "0.14.3";

      src = fetchFromGitHub {
        owner = "lightninglabs";
        repo = "chantools";
        rev = "v${version}";
        hash = "sha256-uPuRMV4xU3T/IniIHb2iuO0GGzO+ssoOPSN3S56/thk=";
      };

      vendorHash = "sha256-S+lPl3h4U8dxJRmpSn/etAjwfpwpJK8Y0A3+ns08O9g=";

      subPackages = [ "cmd/chantools" ];

      ldflags = [
        "-s"
        "-w"
      ];

      checkFlags = [
        "-skip=^TestCompactDBAndDumpChannels$"
        "-timeout=30m"
      ];

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
  ) { };
in
{
  inherit chantools bbolt-cli;
}
