_topPrev: pyfinal: pyprev: {
  example-underdeclared = pyprev.example-underdeclared.overridePythonAttrs (old: {
    build-system = (old.build-system or [ ]) ++ [ pyfinal.hatchling ];
    dependencies = (old.dependencies or [ ]) ++ [
      pyfinal.markdown-it-py
      pyfinal.mdit-py-plugins
    ];
  });
}
