{
  pname,

  src,

  versionPrefix ? "fork",

  doCheck ? false,

  clearPatches ? false,
}:

_final: prev:

{
  ${pname} = prev.${pname}.overrideAttrs (
    _old:
    {
      version = "${versionPrefix}-${src.shortRev or "dev"}";
      inherit src;
    }
    // (
      if doCheck then
        { }
      else
        {
          doCheck = false;
          doInstallCheck = false;
        }
    )
    // (if clearPatches then { patches = [ ]; } else { })
  );
}
