_final: prev: {
  myapp = prev.myapp.override {
    electron_39 = prev.electron_39-bin;
  };
}
