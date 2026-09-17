let
  package = "gvisor";
  goMinorBuilder = "buildGo125Module";
in
_final: prev: {
  ${package} = prev.${package}.override {
    buildGoModule = prev.${goMinorBuilder};
  };
}
