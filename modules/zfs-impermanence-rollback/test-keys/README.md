# Disposable test keys

These keypairs exist **only** so the remote-unlock test can pin an initrd host
identity. `boot.initrd.network.ssh.hostKeys` rejects store paths — the store is
world-readable — so the key cannot be generated at build time and has to be a
committed fixture. nixpkgs does the same for its own initrd-ssh test.

They are generated garbage, used by one VM test, and grant access to nothing.
Do not reuse them for anything, and do not treat their presence as a pattern
worth copying into a real deployment.
