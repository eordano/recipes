# agenix-secret-sibling
#
# A one-line helper for agenix-rekey secret *generators*.
#
# An agenix-rekey generator produces the plaintext of a secret on stdout, which
# the framework then encrypts into `<name>.age`. Many secrets are actually key
# *pairs*: the private half is the secret (encrypted), but the public half is
# not sensitive and you usually want it committed in the clear so other modules
# can reference it (an SSH `.pub`, a GPG `.asc`, an API `public-key`, a
# binary-cache `.pub`, ...).
#
# This helper derives the sibling path for that public half from the secret's
# own `.age` filename: strip the `.age` suffix, append a new extension, and
# shell-escape the result so it is safe to interpolate into the generator's
# shell script. The public file then lands right beside its encrypted private
# counterpart in your secrets tree.
#
# Usage — import it with `lib` applied, then call `secretSibling file ".ext"`
# inside a generator, where `file` is the generator argument holding the
# absolute path to the target `.age` file:
#
#     { lib, ... }:
#     let
#       # this file is a curried function: apply `lib` first.
#       secretSibling = import ./lib/agenix-secret-sibling/default.nix lib;
#     in
#     {
#       age.generators.ssh =
#         { pkgs, file, ... }:
#         ''
#           ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f id_ed25519 -N "" -q
#           # public half lands next to the .age as <name>.pub
#           mv id_ed25519.pub ${secretSibling file ".pub"}
#           cat id_ed25519        # private half -> stdout -> encrypted by agenix
#           rm id_ed25519
#         '';
#     }
#
# Given `file = "/repo/secrets/host-ssh.age"` and `suffix = ".pub"`, the result
# is the shell-escaped string `'/repo/secrets/host-ssh.pub'`.
#
# Traps this guards against:
#   * `escapeShellArg` is not optional. `file` is interpolated straight into a
#     shell heredoc/command; without escaping, a path containing spaces or shell
#     metacharacters would break the generator (or worse). Keep it.
#   * The suffix is a plain string concatenation, so include the leading dot
#     yourself (".pub", not "pub"). This lets you also produce non-dotted
#     siblings if you ever need them.
#   * This only computes the *public* sibling path. Never write the private half
#     into the working directory of the generator — emit it on stdout so agenix
#     encrypts it. A stray plaintext private key left in cwd can end up
#     committed. (See the README for the full generator hygiene note.)
#
# The whole thing is deliberately tiny: it is a curried function of
# `lib -> file -> suffix -> escapedPath`.

lib: file: suffix: lib.escapeShellArg (lib.removeSuffix ".age" file + suffix)
