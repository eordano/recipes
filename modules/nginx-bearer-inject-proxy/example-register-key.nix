{ pkgs, lib }:

{
  description,
  alias,
  secretPath,
  adminKeyEnvFile,
  port,
  keyPrefix ? "",
  extraJsonFields ? { },
}:
let
  extraFields = lib.concatStrings (lib.mapAttrsToList (k: v: ", \"${k}\": ${v}") extraJsonFields);
in
{
  inherit description;
  after = [ "network-online.target" ];
  wants = [ "network-online.target" ];
  wantedBy = [ "multi-user.target" ];

  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    EnvironmentFile = adminKeyEnvFile;
    Restart = "on-failure";
    RestartSec = "30s";
  };
  unitConfig = {
    StartLimitIntervalSec = "10min";
    StartLimitBurst = 5;
  };

  script = ''
    set -eu
    umask 077

    if [ ! -s "${secretPath}" ]; then
      echo "secret not present at ${secretPath}; aborting." >&2
      exit 1
    fi
    KEY="${keyPrefix}$(${pkgs.coreutils}/bin/cat "${secretPath}")"

    # Credential hygiene (the endpoints below are ILLUSTRATIVE -- adapt them to
    # your provisioning API). The admin bearer token is handed to curl via
    # `--config -` (a heredoc on stdin) rather than on argv, so it can never be
    # read from ps / /proc/<pid>/cmdline. The key lookup travels in a request
    # header, and the JSON bodies go through a 0600 temp file referenced from the
    # curl config -- so neither the admin token nor the key value ever appears in
    # a URL query string (which upstreams write to access logs) or on any
    # process's command line.

    # Wait for the upstream to answer before trying to provision against it.
    for _ in $(seq 1 30); do
      ${pkgs.curl}/bin/curl -sf --url "http://127.0.0.1:${toString port}/health" \
        --config - > /dev/null <<CFG && break
    header = "Authorization: Bearer $ADMIN_KEY"
    CFG
      sleep 2
    done

    # Idempotency: if the key already resolves, do nothing. The key is sent as a
    # request header, never as a URL query parameter.
    HTTP_CODE=$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' \
      --url "http://127.0.0.1:${toString port}/key/info" \
      --config - <<CFG
    header = "Authorization: Bearer $ADMIN_KEY"
    header = "X-Api-Key: $KEY"
    CFG
    )

    if [ "$HTTP_CODE" = "200" ]; then
      echo "Key (alias=${alias}) already exists, skipping."
    else
      # JSON bodies are written to a private (umask 077) temp file and referenced
      # from the curl config, keeping both the admin token and the key value off
      # every process's argv.
      BODY=$(${pkgs.coreutils}/bin/mktemp)
      trap '${pkgs.coreutils}/bin/rm -f "$BODY"' EXIT

      # Clear any stale key sharing this alias, then (re)create.
      ${pkgs.coreutils}/bin/cat > "$BODY" <<JSON
    {"key_aliases":["${alias}"]}
    JSON
      ${pkgs.curl}/bin/curl -s -X POST \
        --url "http://127.0.0.1:${toString port}/key/delete" \
        --config - > /dev/null <<CFG || true
    header = "Authorization: Bearer $ADMIN_KEY"
    header = "Content-Type: application/json"
    data-binary = "@$BODY"
    CFG

      ${pkgs.coreutils}/bin/cat > "$BODY" <<JSON
    {"key": "$KEY", "key_alias": "${alias}"${extraFields}}
    JSON
      ${pkgs.curl}/bin/curl -sf -X POST \
        --url "http://127.0.0.1:${toString port}/key/generate" \
        --config - > /dev/null <<CFG
    header = "Authorization: Bearer $ADMIN_KEY"
    header = "Content-Type: application/json"
    data-binary = "@$BODY"
    CFG
      echo "Key (alias=${alias}) registered."
    fi
  '';
}
