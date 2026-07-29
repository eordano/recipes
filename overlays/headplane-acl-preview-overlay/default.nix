# headplane-acl-preview-overlay
#
# Swap an upstream web-UI package's stub / "coming soon" component for a
# working local one via a `overrideAttrs` `postPatch`, WITHOUT forking the
# upstream repo. Here the target is Headplane's ACL "preview" tab, whose
# upstream renders a `<Construction />` placeholder; we drop in a real
# client-side access-matrix component instead.
#
# The technique is generic. Any packaged JS/TS app that ships a placeholder
# React (or Vue/Svelte) component can have it replaced this way as long as the
# app is built FROM SOURCE inside the derivation (so a `postPatch` runs before
# the bundler). The four moves below are the reusable pattern:
#
#   1. cp                — drop your replacement component into the source tree
#   2. sed insert import — wire the new component into the page that renders it
#   3. substituteInPlace — swap the placeholder JSX for your component's JSX
#   4. sed delete        — remove the leftover "coming soon" prose so it does
#                          not render alongside your component
#
# Import it as a nixpkgs overlay:
#
#   nixpkgs.overlays = [ (import ./headplane-acl-preview-overlay) ];
#
# The replacement component lives beside this file as
# `acl-preview-component.tsx`; edit it to taste. The upstream source paths
# (app/routes/acls/...) are Headplane-specific — retarget them for your app.

final: prev: {
  headplane = prev.headplane.overrideAttrs (old: {
    # gnused is needed for the in-place line insert/delete. Some upstream
    # builders already have it; appending is safe either way.
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ final.gnused ];

    # Append to any existing postPatch rather than clobbering it — the
    # upstream package may already patch its own sources.
    postPatch = (old.postPatch or "") + ''
      # 1. Copy the replacement component into the app source tree.
      cp ${./acl-preview-component.tsx} app/routes/acls/acl-preview.tsx

      # 2. Inject the import at the top of the page that renders the stub.
      #    `1i` inserts before line 1 (imports must precede any JSX).
      sed -i '1i import AclPreview from "./acl-preview";' app/routes/acls/overview.tsx

      # 3. Replace the placeholder element with our component.
      #    --replace-fail makes the build FAIL LOUDLY if upstream renames or
      #    removes `<Construction />` — far better than a silent no-op that
      #    ships the stub. Re-check this string whenever you bump the package.
      substituteInPlace app/routes/acls/overview.tsx \
        --replace-fail '<Construction />' '<AclPreview policy={codePolicy} />'

      # 4. Delete upstream's leftover "coming soon" paragraph so it does not
      #    render above/below our component. This is a range delete from the
      #    opening `<p className="mt-4 ...>` through its closing `</p>`.
      #    ORDERING: this runs AFTER the substitute above; the two edits touch
      #    different lines, but keep the delete last so the anchor text you
      #    match here is not accidentally altered by an earlier edit.
      sed -i '/<p className="mt-4/,/<\/p>/d' app/routes/acls/overview.tsx
    '';
  });
}
