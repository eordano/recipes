# xorg-silence-aliases
#
# A nixpkgs overlay that silences the eval-time deprecation warnings emitted for
# legacy `pkgs.xorg.<name>` accesses.
#
# nixpkgs keeps promoting packages out of the `xorg` package scope up to the
# top level (e.g. `xorg.xrandr` -> `xrandr`). Each legacy access to the old
# `xorg.<name>` spelling then trips a `builtins.trace` deprecation warning at
# evaluation time. This overlay re-points every promoted name back onto the
# `xorg` attrset so BOTH spellings resolve to the *same* derivation and the
# warning disappears.
#
# Usage:
#   nixpkgs.overlays = [ (import ./xorg-silence-aliases) ];
# or as a flake overlay:
#   overlays.default = import ./overlays/xorg-silence-aliases;
#
# The list below is the set of names that have (at various nixpkgs versions)
# been promoted out of `xorg`. Rather than hardcode `xorg.foo = final.foo` for
# each — which would break the day a name is *not* present at the top level on
# your channel — we alias only the names that actually exist as a top-level
# attribute of `final`. That keeps the overlay a safe drop-in across channels:
# names that have not been promoted (yet, or on your pin) are simply left alone.
#
# `final` (a.k.a. `self`) is used for the right-hand sides on purpose: it is the
# fully-overlaid package set, so the alias tracks any *later* overlay that
# replaces the top-level derivation. Using `prev` here would pin the alias to
# the pre-overlay value and could desync the two spellings.

final: prev:

let
  # Names that have been (or may be) promoted out of the `xorg` scope to the
  # top level. Extend this list if your channel warns about a name not covered.
  promotedNames = [
    "appres"
    "bdftopcf"
    "bitmap"
    "editres"
    "fonttosfnt"
    "gccmakedep"
    "iceauth"
    "ico"
    "imake"
    "libdmx"
    "libfontenc"
    "libpciaccess"
    "libxcb"
    "libxcvt"
    "libxkbfile"
    "libxshmfence"
    "listres"
    "lndir"
    "luit"
    "makedepend"
    "mkfontscale"
    "oclock"
    "pixman"
    "sessreg"
    "setxkbmap"
    "smproxy"
    "transset"
    "viewres"
    "wrapWithXFileSearchPathHook"
    "x11perf"
    "xauth"
    "xbacklight"
    "xbitmaps"
    "xcalc"
    "xclock"
    "xcmsdb"
    "xcompmgr"
    "xconsole"
    "xcursorgen"
    "xdm"
    "xdpyinfo"
    "xdriinfo"
    "xev"
    "xeyes"
    "xfd"
    "xfontsel"
    "xfs"
    "xfsinfo"
    "xgamma"
    "xgc"
    "xhost"
    "xinit"
    "xinput"
    "xkbcomp"
    "xkbevd"
    "xkbprint"
    "xkbutils"
    "xkill"
    "xload"
    "xlsatoms"
    "xlsclients"
    "xlsfonts"
    "xmag"
    "xmessage"
    "xmodmap"
    "xmore"
    "xorgproto"
    "xpr"
    "xprop"
    "xrandr"
    "xrdb"
    "xrefresh"
    "xset"
    "xsetroot"
    "xsm"
    "xstdcmap"
    "xtrans"
    "xvfb"
    "xvinfo"
    "xwd"
    "xwininfo"
    "xwud"
  ];

  lib = prev.lib;

  # Keep only names that are actually present at the top level of the overlaid
  # set, and map each to its promoted top-level derivation.
  aliases = lib.genAttrs
    (lib.filter (name: lib.hasAttr name final) promotedNames)
    (name: final.${name});
in
{
  xorg = prev.xorg // aliases;
}
