final: prev: {
  headplane = prev.headplane.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ final.gnused ];

    postPatch = (old.postPatch or "") + ''
      # 1. Copy the replacement component into the app source tree.
      cp ${./acl-preview-component.tsx} app/routes/acls/acl-preview.tsx

      # 2. Inject the import at the top of the page that renders the stub.
      #    `1i` inserts before line 1 (imports must precede any JSX).
      sed -i '1i import AclPreview from "./acl-preview";' app/routes/acls/overview.tsx

      # 3. Replace the placeholder element with our component.
      #    --replace-fail makes the build FAIL LOUDLY if upstream renames or
      #    removes `<Construction />` -- far better than a silent no-op that
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
