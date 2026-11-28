#!/usr/bin/env bash
# Offline test of deploy/swarm/settings.sh. No network, no Docker, no real whiptail/openssl: docker, whiptail, openssl, update.sh and
# swarm-deploy.sh are stubs in a temp copy of the tree; the env file is a temp file.
# Covers: --list/--get/--set/--unset/--info/--check, rejection of invalid values, secrets never printed or written (the test looks for
# the generated key in the env file, its backups and all output), mode 0600 and backups, atomic writing, --generate (creates the Swarm
# secret only when missing, sets SETTINGS_KEY_ENABLED=true, never rolls out), menu flows (apply only after confirmation), Bash version.
# Usage: scripts/test-settings.sh   (needs bash 4.4+; macOS: /opt/homebrew/bin/bash scripts/test-settings.sh)
# shellcheck disable=SC2016,SC2012  # test data contains $ and backticks on purpose; ls is fine for counting files in a temp dir
set -uo pipefail
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  echo "FAIL test-settings.sh needs bash 4.4+ (found $BASH_VERSION). macOS: brew install bash, then /opt/homebrew/bin/bash $0" >&2
  exit 1
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/deploy/swarm"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
DIR="$WORK/repo/deploy/swarm"; mkdir -p "$DIR" "$WORK/repo/scripts" "$WORK/bin" "$WORK/secrets" "$WORK/envdir"
cp "$SRC"/settings.sh "$SRC"/config-registry.tsv "$SRC"/config-extra.tsv "$SRC"/stack.env.example "$SRC"/placement.sh "$SRC"/stack*.yaml "$DIR/" 2>/dev/null
[ -f "$SRC/config-help.tsv" ] && cp "$SRC/config-help.tsv" "$DIR/"
chmod +x "$DIR/settings.sh" 2>/dev/null
# Roll-out scripts are stubs that only log: --set/--unset/--generate must never call them.
cat > "$DIR/update.sh" <<'EOF'
#!/usr/bin/env bash
echo "update.sh $*" >> "$STUB_LOG.rollout"
EOF
cat > "$WORK/repo/scripts/swarm-deploy.sh" <<'EOF'
#!/usr/bin/env bash
echo "swarm-deploy.sh $*" >> "$STUB_LOG.rollout"
EOF
chmod +x "$DIR/update.sh" "$WORK/repo/scripts/swarm-deploy.sh"
# The generated key the openssl stub returns: 7 + 36 letters + "=" = 44 base64 characters, easy to search for.
KEYVALUE="TESTKEY$(printf 'A%.0s' $(seq 1 36))="
cat > "$WORK/bin/openssl" <<EOF
#!/usr/bin/env bash
echo "openssl \$*" >> "\$STUB_LOG.openssl"
if [ "\${STUB_OPENSSL:-ok}" != ok ]; then exit 1; fi
if [ "\$1 \$2 \$3" = "rand -base64 32" ]; then echo '$KEYVALUE'; exit 0; fi
exit 1
EOF
cat > "$WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
# Swarm stub: secrets live as files in $STUB_SECRETS_DIR (the value arrives on stdin and never in the argument list).
echo "docker $*" >> "$STUB_LOG.docker"
if [ "${STUB_DOCKER:-ok}" = down ]; then echo "Cannot connect to the Docker daemon" >&2; exit 1; fi
case "$1 $2" in
  "info --format") if [ "${STUB_SWARM:-manager}" = manager ]; then echo true; else echo false; fi; exit 0 ;;
  "secret inspect") if [ -f "$STUB_SECRETS_DIR/$3" ]; then echo '[{"ID":"x"}]'; exit 0; fi
                    if [ "${STUB_SWARM:-manager}" != manager ]; then echo "Error response from daemon: This node is not a swarm manager." >&2; exit 1; fi
                    echo "Error: no such secret: $3" >&2; exit 1 ;;
  "secret create") [ "${STUB_CREATE_FAIL:-0}" = 0 ] || { echo "create failed" >&2; exit 1; }
                   [ ! -f "$STUB_SECRETS_DIR/$3" ] || { echo "secret already exists" >&2; exit 1; }
                   cat > "$STUB_SECRETS_DIR/$3"; echo "id-$3"; exit 0 ;;
esac
exit 1
EOF
cat > "$WORK/bin/whiptail" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" != --infobox ] || exit 0; done
n=$(cat "$STUB_STATE" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_STATE"
{ printf '#%s:' "$n"; printf ' [%s]' "$@"; echo; } >> "$STUB_LOG"
prev=""; for a in "$@"; do [ "$prev" != --textbox ] || cp "$a" "$STUB_LOG.textbox.$n"; prev="$a"; done
line="$(sed -n "${n}p" "$STUB_SCRIPT")"
if [ -z "$line" ]; then echo "stub: script exhausted at call $n" >> "$STUB_LOG"; exit 255; fi
rc="${line%%|*}"; out="${line#*|}"
printf '%b' "$out" >&2
exit "$rc"
EOF
# mv stub: fails on demand (atomic-write test), records the arguments, otherwise the real mv.
REALMV="$(command -v mv)"
cat > "$WORK/bin/mv" <<EOF
#!/usr/bin/env bash
echo "mv \$*" >> "\$STUB_LOG.mv"
if [ "\${STUB_MV_FAIL:-0}" = 1 ]; then echo "mv: simulated failure" >&2; exit 1; fi
exec "$REALMV" "\$@"
EOF
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"
export STUB_LOG="$WORK/log" STUB_SECRETS_DIR="$WORK/secrets" STUB_STATE="$WORK/state"
TMO=""; command -v timeout >/dev/null 2>&1 && TMO="timeout 60"

ENVF="$WORK/envdir/stack.env"
fail=0; total=0
check() { # name, command...
  local name="$1"; shift
  total=$((total + 1))
  if "$@" >/dev/null 2>&1; then echo "ok   $name"; else echo "FAIL $name"; fail=$((fail + 1)); fi
}
fails() { ! "$@"; }
eq() { [ "$1" = "$2" ]; }
has() { grep -qF -- "$2" <<< "$1"; }
hasnt() { ! grep -qF -- "$2" <<< "$1"; }
hasall() { local t="$1" w; shift; for w in "$@"; do has "$t" "$w" || return 1; done; }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

fresh() {
  rm -rf "$WORK/envdir" "$WORK/secrets" "$WORK"/log "$WORK"/log.* "$WORK/state"; mkdir -p "$WORK/envdir" "$WORK/secrets"
  cat > "$ENVF" <<'EOF'
# Kommentar oben, bleibt erhalten
TODO_STACK=todo
TODO_IMAGE_TAG=sha-abc1234
RP_ID=todo.example.org
RP_ORIGIN=https://todo.example.org
DB_HOST=db.prod.internal
DB_PORT=3306
BACKEND_PORT=38080
BACKEND_REPLICAS=3

# Hinweis zu SMTP
#SMTP_PORT=587
#SYNC_RETENTION_DAYS=90
UNKNOWN_THING='keep me'
# Ende
EOF
  chmod 600 "$ENVF"
}
S() { ( cd "$DIR" && $TMO ./settings.sh --env "$ENVF" "$@" ); }
sha() { cksum < "$ENVF"; }
nbackups() { ls "$ENVF".bak.* 2>/dev/null | wc -l | tr -d ' '; }
nolines() { ! grep -q . "$1" 2>/dev/null; }
call_n() { awk -v n="$1" '/^#[0-9]+:/ { p = ($0 ~ "^#" n ":") } p' "$WORK/log"; }
menu() { # answer lines "RC|output" as arguments; the menu output lands in $WORK/menu.out
  : > "$WORK/script"; local l; for l in "$@"; do printf '%s\n' "$l" >> "$WORK/script"; done
  export STUB_SCRIPT="$WORK/script"
  rm -f "$WORK/state" "$WORK/log" "$WORK"/log.*
  ( cd "$DIR" && SETTINGS_ROWS=24 SETTINGS_COLS=80 $TMO ./settings.sh --env "$ENVF" > "$WORK/menu.out" 2>&1 < /dev/null ); MENU_RC=$?
}
# Everything the whiptail stub was shown (dialog arguments and text boxes).
menutext() { cat "$WORK/log" "$WORK"/log.textbox.* 2>/dev/null; }

# ------------------------------------------------------------- basics
fresh
check "help prints usage" has "$(S --help 2>&1)" "--generate"
check "usage: an unknown option exits with 64" bash -c "cd '$DIR' && ./settings.sh --env '$ENVF' --bogus >/dev/null 2>&1; [ \$? -eq 64 ]"
printf 'SENTINEL-OLD-BACKUP\n' > "$ENVF.bak"
S --set SYNC_RETENTION_DAYS=30 > "$WORK/out" 2>&1
check "set: a commented #KEY= line is activated in place" eq "$(sed -n 13p "$ENVF")" "SYNC_RETENTION_DAYS=30"
check "set: get returns the value" eq "$(S --get SYNC_RETENTION_DAYS)" 30
check "set: comments and unknown lines stay" bash -c "grep -qx '# Kommentar oben, bleibt erhalten' '$ENVF' && grep -qx \"UNKNOWN_THING='keep me'\" '$ENVF' && grep -qx '#SMTP_PORT=587' '$ENVF' && grep -qx '# Ende' '$ENVF'"
check "set: mode stays 0600" eq "$(mode_of "$ENVF")" 600
check "set: backup <file>.bak.YYYYMMDD-HHMMSS exists" bash -c "ls '$ENVF'.bak.[0-9]*-[0-9]* >/dev/null 2>&1"
check "set: backup has mode 0600" bash -c "for f in '$ENVF'.bak.[0-9]*; do [ \"\$(stat -c '%a' \"\$f\" 2>/dev/null || stat -f '%Lp' \"\$f\")\" = 600 ] || exit 1; done"
check "set: backup holds the old content" bash -c "grep -qx '#SYNC_RETENTION_DAYS=90' \"\$(ls '$ENVF'.bak.[0-9]*-[0-9]* | head -1)\""
check "set: an existing <file>.bak is left alone" eq "$(cat "$ENVF.bak")" SENTINEL-OLD-BACKUP
check "set: output names the backup and says nothing was rolled out" bash -c "grep -q 'Sicherung:' '$WORK/out' && grep -q 'nicht ausgerollt' '$WORK/out'"
check "set: no temp files left behind" bash -c "! ls -A '$WORK/envdir' | grep -q '^\.settings'"
S --set SYNC_RETENTION_DAYS=30 >/dev/null; b="$(nbackups)"
check "set: an unchanged value creates no new backup" eq "$b" 1
S --set CLEANUP_INTERVAL_MINUTES=120 --set LIVE_POLL_MS=2000 >/dev/null
check "set: several values in one run" bash -c "grep -qx 'CLEANUP_INTERVAL_MINUTES=120' '$ENVF' && grep -qx 'LIVE_POLL_MS=2000' '$ENVF'"
check "set: a new variable is appended" eq "$(tail -n1 "$ENVF")" "LIVE_POLL_MS=2000"
S --set SYNC_RETENTION_DAYS=007 >/dev/null 2>&1; rc=$?
check "set: leading zeros are rejected" eq "$rc" 3
S --set PASSWORD_LOGIN_ENABLED=true >/dev/null
check "set: bool true is stored" grep -qx 'PASSWORD_LOGIN_ENABLED=true' "$ENVF"
S --set 'INSTANCE_NAME=Mein Todolino' >/dev/null
check "set: values with spaces are quoted so that sourcing works" grep -qx 'INSTANCE_NAME="Mein Todolino"' "$ENVF"
check "set: the quoted file round-trips through --get" eq "$(S --get INSTANCE_NAME)" "Mein Todolino"
check "set: the file still sources like update.sh does" bash -c "( set -a; . '$ENVF'; [ \"\$INSTANCE_NAME\" = 'Mein Todolino' ] && [ \"\$BACKEND_PORT\" = 38080 ] )"
S --set 'INSTANCE_NAME=Fritz "Der" Server' >/dev/null
check "set: a double quote switches to single quotes" grep -qx "INSTANCE_NAME='Fritz \"Der\" Server'" "$ENVF"
check "set: nothing was rolled out" nolines "$WORK/log.rollout"

# ------------------------------------------------------------- rejection of invalid values
fresh; before="$(sha)"
for pair in INSTANCE_NAME= PASSWORD_LOGIN_ENABLED=yes PASSWORD_LOGIN_ENABLED=TRUE SMTP_SECURITY=ssl SMTP_PORT=0 SMTP_PORT=70000 SMTP_PORT=abc \
            ATTACHMENT_MAX_BYTES=100 ATTACHMENT_MAX_BYTES=1e3 ATTACHMENT_STORAGE=ftp LIVE_POLL_MS=50 CLEANUP_INTERVAL_MINUTES=-1 \
            BACKEND_REPLICAS=0 BACKEND_PORT=99999 BACKEND_CPU_LIMIT=abc DB_PORT=0 DB_NAME=1bad DB_USER=-x TODO_STACK=Bad_Name TODO_IMAGE_TAG='a b' \
            BACKEND_MEMORY_LIMIT=lots RP_ID=Bad_Host RP_ORIGIN=http://evil.example RP_ORIGIN=https://todo.example.org/path RP_ORIGIN=todo.example.org \
            OAUTH_ISSUER=ftp://x APNS_KEY_ID=abc APNS_TEAM_ID=abcde12345 APNS_ENVIRONMENT=staging MAIL_FROM=notamail SMTP_HOST='a b' \
            S3_ENDPOINT=ftp://x AASA_APP_IDS=a,,b SETTINGS_KEY_SECRET='bad name' SETTINGS_KEY_ENABLED=1 PINNED_REPLICAS=x UNKNOWN_VAR=1 \
            OUTBOUND_TARGET_PROTECTION=none; do
  S --set "$pair" >/dev/null 2>&1; rc=$?
  check "reject: $pair" bash -c "[ $rc -ne 0 ] && [ '$(sha)' = '$before' ]"
done
for v in 'a$HOME' 'a`id`' 'a\b' "a'b\"c"; do
  S --set "INSTANCE_NAME=$v" >/dev/null 2>&1; rc=$?
  check "reject: unsafe characters in $v" bash -c "[ $rc -ne 0 ] && [ '$(sha)' = '$before' ]"
done
S --set $'INSTANCE_NAME=two\nlines' >/dev/null 2>&1; rc=$?
check "reject: line break in the value" bash -c "[ $rc -ne 0 ] && [ '$(sha)' = '$before' ]"
check "reject: no backup after failures" eq "$(nbackups)" 0
S --set SYNC_RETENTION_DAYS=999999 --set LIVE_POLL_MS=2000 >/dev/null 2>&1
check "reject: one invalid value stops the whole run" bash -c "[ '$(sha)' = '$before' ] && ! grep -q 'LIVE_POLL_MS' '$ENVF'"
out="$(S --set 'SMTP_PORT=70000' 2>&1)"
check "reject: the message names variable and range" bash -c "grep -q 'SMTP_PORT' <<< \"\$1\" && grep -q '65535' <<< \"\$1\"" _ "$out"
out="$(S --set 'ATTACHMENT_STORAGE=ftp' 2>&1)"
check "reject: choices are listed" has "$out" "database, s3"
check "set: --set without = is a usage error" bash -c "cd '$DIR' && ./settings.sh --env '$ENVF' --set FOO >/dev/null 2>&1; [ \$? -eq 64 ]"

# conflicts: a change that would create a new error is refused, related values go in one run
fresh; before="$(sha)"
S --set MAIL_ENABLED=true >/dev/null 2>&1; rc=$?
check "conflict: MAIL_ENABLED=true alone is refused (SMTP_HOST, SMTP_USER, MAIL_FROM missing)" bash -c "[ $rc -eq 3 ] && [ '$(sha)' = '$before' ]"
S --set MAIL_ENABLED=true --set SMTP_HOST=smtp.example.org --set SMTP_USER=todolino@example.org --set MAIL_FROM=todolino@example.org >/dev/null 2>&1; rc=$?
check "conflict: the whole mail set in one run is accepted" bash -c "[ $rc -eq 0 ] && grep -qx 'MAIL_ENABLED=true' '$ENVF'"
fresh
S --set APNS_ENABLED=true >/dev/null 2>&1; rc=$?
check "conflict: APNS_ENABLED=true without key ID and team ID is refused" eq "$rc" 3
S --set GITHUB_APP_ENABLED=true >/dev/null 2>&1; rc=$?
check "conflict: GITHUB_APP_ENABLED=true without app ID, slug and client ID is refused" eq "$rc" 3
S --set GITHUB_APP_ENABLED=true --set GITHUB_APP_ID=424242 --set GITHUB_APP_SLUG=todolino-deploy \
  --set GITHUB_APP_CLIENT_ID=Iv23liTEST >/dev/null 2>&1; rc=$?
check "github: the whole app set in one run is accepted" bash -c "[ $rc -eq 0 ] && grep -qx 'GITHUB_APP_ID=424242' '$ENVF'"
S --set GITHUB_APP_INSTALLATION_ID=777 >/dev/null 2>&1; rc=$?
check "github: the old installation id without repositories is refused (they belong together)" eq "$rc" 3
S --set GITHUB_APP_INSTALLATION_ID=777 --set GITHUB_APP_REPOSITORIES=A53494A1-2866-449C-970D-B978BE4D5816=acme/site >/dev/null 2>&1; rc=$?
check "github: the old pair together is accepted (transition)" eq "$rc" 0
out="$(S --set GITHUB_APP_CLIENT_SECRET=CLIENTSECRETMATERIAL 2>&1)"; rc=$?
check "github: the client secret is never written to the file; the hint names the secret" bash -c "[ $rc -eq 2 ] && ! grep -q CLIENTSECRETMATERIAL '$ENVF' && grep -q todo_github_app_client_secret <<< \"\$1\"" _ "$out"
out="$(S --set GITHUB_APP_PRIVATE_KEY=KEYMATERIAL 2>&1)"; rc=$?
check "github: the private key is never written to the file; the hint names the secret" bash -c "[ $rc -eq 2 ] && ! grep -q KEYMATERIAL '$ENVF' && grep -q todo_github_app_key <<< \"\$1\"" _ "$out"
fresh
out="$(S --set ATTACHMENT_STORAGE=s3 2>&1)"; rc=$?
check "conflict: ATTACHMENT_STORAGE=s3 without S3_ENDPOINT is only a warning (the endpoint may live in the PWA)" bash -c "[ $rc -eq 0 ] && grep -q 'WARNUNG.*S3_ENDPOINT' <<< \"\$1\"" _ "$out"
S --set RP_ID=other.example >/dev/null 2>&1; rc=$?
check "conflict: RP_ID must fit the host of RP_ORIGIN" eq "$rc" 3
S --set RP_ID=example.org >/dev/null 2>&1; rc=$?
check "conflict: a parent domain of the origin host is allowed" eq "$rc" 0
S --set SETTINGS_KEY_PREVIOUS_SECRET=old_key >/dev/null 2>&1; rc=$?
check "conflict: a previous key without SETTINGS_KEY_ENABLED=true is refused" eq "$rc" 3
S --set PLACEMENT_CONSTRAINTS='node.role=worker' >/dev/null 2>&1; rc=$?
check "conflict: placement.sh rejects a bad constraint" eq "$rc" 3
S --set PLACEMENT_CONSTRAINTS='node.role==worker' >/dev/null 2>&1; rc=$?
check "conflict: a valid constraint is accepted" eq "$rc" 0
S --set PINNED_NODE=node-2 --set BACKEND_PINNED_PORT=38080 >/dev/null 2>&1; rc=$?
check "conflict: BACKEND_PINNED_PORT equal to BACKEND_PORT is refused" eq "$rc" 3

# ------------------------------------------------------------- unset
fresh
S --set SYNC_RETENTION_DAYS=30 >/dev/null
S --unset SYNC_RETENTION_DAYS >/dev/null
check "unset: the line is commented out, the value stays readable" grep -qx '#SYNC_RETENTION_DAYS=30' "$ENVF"
check "unset: get returns the default again" eq "$(S --get SYNC_RETENTION_DAYS)" 90
check "unset: a variable that is not set is no error" S --unset CLEANUP_INTERVAL_MINUTES
check "unset: an unknown variable is refused" fails S --unset NOPE_X
check "unset: sets nothing, so no backup for an unset variable" bash -c "b=\$(ls '$ENVF'.bak.* | wc -l); S() { ( cd '$DIR' && ./settings.sh --env '$ENVF' \"\$@\" ); }; S --unset CLEANUP_INTERVAL_MINUTES >/dev/null; [ \$(ls '$ENVF'.bak.* | wc -l) = \$b ]"
S --unset BACKEND_PORT >/dev/null
check "unset: --unset removed a template variable from the file" eq "$(S --get BACKEND_PORT)" 38080
check "unset: nothing was rolled out" nolines "$WORK/log.rollout"

# ------------------------------------------------------------- --get, --info, --list
fresh
check "get: file value" eq "$(S --get DB_HOST)" db.prod.internal
check "get: registry default" eq "$(S --get LIVE_POLL_MS)" 1500
check "get: the template value is the default of a deploy variable" eq "$(S --get OAUTH_ISSUER)" "https://todo.linolaske.de"
check "get: the registry default wins over the template (application default)" eq "$(S --get AASA_APP_IDS)" ""
check "get: unknown variable is refused" fails S --get NOPE_X
out="$(S --info SMTP_SECURITY 2>&1)"
check "info: type, default and effect" bash -c "grep -q 'starttls' <<< \"\$1\" && grep -q 'Typ:' <<< \"\$1\" && grep -q 'Default:' <<< \"\$1\" && grep -q 'Wirkung:' <<< \"\$1\"" _ "$out"
out="$(S --info SETTINGS_KEY_ENABLED 2>&1)"
check "info: long help text from config-help.tsv" has "$out" "--generate SETTINGS_ENCRYPTION_KEY"
check "info: unknown variable is refused" fails S --info NOPE_X
out="$(S --list 2>&1)"
check "list: header, defaults and sources" bash -c "grep -q '^VARIABLE' <<< \"\$1\" && grep -Eq '^LIVE_POLL_MS +1500 +1500 +Default' <<< \"\$1\" && grep -Eq '^DB_HOST +db.prod.internal .* Datei' <<< \"\$1\"" _ "$out"
check "list: unknown variable is flagged" has "$out" "UNKNOWN_THING"
check "list: at least 60 variables" bash -c "[ \$(grep -c . <<< \"\$1\") -ge 60 ]" _ "$out"
check "list: the four secret settings are listed as (Geheimnis), without value" eq "$(grep -cE '^(SMTP_PASSWORD|APNS_KEY|S3_SECRET_KEY|S3_ACCESS_KEY) +\(Geheimnis\)' <<< "$out")" 4

# ------------------------------------------------------------- --check
fresh
out="$(S --check 2>&1)"; rc=$?
check "check: a clean file has no error" bash -c "[ $rc -eq 0 ] && grep -q '0 Fehler' <<< \"\$1\"" _ "$out"
check "check: an unknown variable is a warning" has "$out" "WARNUNG  UNKNOWN_THING"
check "check: ... which does not fail the run" eq "$rc" 0
chmod 644 "$ENVF"; out="$(S --check 2>&1)"
check "check: mode 644 is a warning" has "$out" "Dateimodus"
chmod 600 "$ENVF"
fresh; printf 'SYNC_RETENTION_DAYS=99999\n' >> "$ENVF"
out="$(S --check 2>&1)"; rc=$?
check "check: out-of-range value is an error (exit 1)" bash -c "[ $rc -eq 1 ] && grep -q 'FEHLER.*SYNC_RETENTION_DAYS' <<< \"\$1\"" _ "$out"
fresh; printf 'FOO_BAR=$(id)\n' >> "$ENVF"
check "check: shell expression in the file is an error" has "$(S --check 2>&1)" "FOO_BAR"
fresh; printf 'MAIL_ENABLED=true\n' >> "$ENVF"
out="$(S --check 2>&1)"; rc=$?
check "check: MAIL_ENABLED without SMTP_HOST/SMTP_USER/MAIL_FROM" bash -c "[ $rc -eq 1 ] && grep -q 'SMTP_HOST' <<< \"\$1\" && grep -q 'MAIL_FROM' <<< \"\$1\"" _ "$out"
printf 'SMTP_HOST=smtp.example.org\nSMTP_USER=a@example.org\nMAIL_FROM=a@example.org\n' >> "$ENVF"
out="$(S --check 2>&1)"; rc=$?
check "check: complete mail settings pass" eq "$rc" 0
check "check: SMTP_USER from the environment: warn about SMTP_PORT/SMTP_SECURITY" has "$out" "SMTP_SECURITY"
fresh; printf 'APNS_ENABLED=true\n' >> "$ENVF"
out="$(S --check 2>&1)"; rc=$?
check "check: APNS_ENABLED without key and team ID" bash -c "[ $rc -eq 1 ] && grep -q 'APNS_KEY_ID' <<< \"\$1\"" _ "$out"
fresh; sed -i.tmp '/^DB_HOST=/d' "$ENVF"; rm -f "$ENVF.tmp"
out="$(S --check 2>&1)"; rc=$?
check "check: missing DB_HOST is an error (stack.yaml requires it)" bash -c "[ $rc -eq 1 ] && grep -q 'DB_HOST' <<< \"\$1\"" _ "$out"
fresh; printf 'DB_HOST=db.example.internal\n' >> "$ENVF"
check "check: placeholder host is a warning" has "$(S --check 2>&1)" "Platzhalter"
fresh; printf 'SETTINGS_KEY_SECRET=my_key\n' >> "$ENVF"
check "check: SETTINGS_KEY_SECRET without SETTINGS_KEY_ENABLED is a warning" has "$(S --check 2>&1)" "SETTINGS_KEY_ENABLED"
fresh; printf 'SETTINGS_KEY_ENABLED=true\nSETTINGS_KEY_PREVIOUS_SECRET=todo_settings_key\n' >> "$ENVF"
check "check: previous secret equal to the current one is an error" fails S --check
fresh; printf 'PINNED_REPLICAS=2\n' >> "$ENVF"
check "check: PINNED_REPLICAS without PINNED_NODE is a note" has "$(S --check 2>&1)" "HINWEIS"
fresh; ln -s "$ENVF" "$WORK/envdir/link.env"
check "check: a symlink as env file is an error" bash -c "cd '$DIR' && ! ./settings.sh --env '$WORK/envdir/link.env' --check >/dev/null 2>&1"
check "set: a symlink as env file is refused" bash -c "cd '$DIR' && ! ./settings.sh --env '$WORK/envdir/link.env' --set LIVE_POLL_MS=2000 >/dev/null 2>&1"
rm -f "$WORK/envdir/link.env"
check "check: a missing env file is a warning, not an error" bash -c "cd '$DIR' && ./settings.sh --env '$WORK/envdir/none.env' --check 2>&1 | grep -q 'WARNUNG'"
check "set: a missing env file is refused (nothing is created)" bash -c "cd '$DIR' && ! ./settings.sh --env '$WORK/envdir/none.env' --set LIVE_POLL_MS=2000 >/dev/null 2>&1 && [ ! -e '$WORK/envdir/none.env' ]"
fresh; printf 'INSTANCE_NAME="Max \\"Muster\\" \\$HOME"\n' >> "$ENVF"
check "check: an escaped quote or dollar in the file is reported" has "$(S --check 2>&1)" "INSTANCE_NAME"
fresh; before="$(sha)"
check "check: --check never writes" bash -c "S() { ( cd '$DIR' && ./settings.sh --env '$ENVF' \"\$@\" ); }; S --check >/dev/null 2>&1; [ '$before' = \"\$(cksum < '$ENVF')\" ] && [ \"\$(ls '$ENVF'.bak.* 2>/dev/null | wc -l | tr -d ' ')\" = 0 ]"

# ------------------------------------------------------------- secrets
fresh; before="$(sha)"
for pair in SMTP_PASSWORD=geheim123 APNS_KEY=geheim123 S3_SECRET_KEY=geheim123 S3_ACCESS_KEY=geheim123 DB_PASSWORD=geheim123 BOOTSTRAP_TOKEN=geheim123 \
            SETTINGS_ENCRYPTION_KEY=geheim123 SETTINGS_KEY=geheim123 MY_API_TOKEN=geheim123 SOME_SECRET=geheim123; do
  S --set "$pair" >"$WORK/out" 2>&1; rc=$?
  check "secret: $pair refused, file unchanged, value never echoed" bash -c "[ $rc -ne 0 ] && [ '$(sha)' = '$before' ] && ! grep -q geheim123 '$WORK/out'"
done
check "secret: the refusal points to docker secret" bash -c "cd '$DIR' && ./settings.sh --env '$ENVF' --set SMTP_PASSWORD=x 2>&1 | grep -q 'docker secret create todo_smtp_password'"
for k in SMTP_PASSWORD APNS_KEY S3_SECRET_KEY S3_ACCESS_KEY DB_PASSWORD SETTINGS_ENCRYPTION_KEY BOOTSTRAP_TOKEN; do
  check "secret: --get $k refuses" fails S --get "$k"
done
printf 'DB_PASSWORD=hunter2\nFOO_TOKEN=tokvalue77\nSETTINGS_ENCRYPTION_KEY=sekret999\nSMTP_PASSWORD=smtp-pass-1\n' >> "$ENVF"
out="$(S --check 2>&1)"; rc=$?
check "secret in the file: --check reports an error" eq "$rc" 1
check "secret in the file: --check shows no value" bash -c "! grep -qE 'hunter2|tokvalue77|sekret999|smtp-pass-1' <<< \"\$1\"" _ "$out"
out="$(S --list 2>&1)"
check "secret in the file: --list shows no value" bash -c "! grep -qE 'hunter2|tokvalue77|sekret999|smtp-pass-1' <<< \"\$1\"" _ "$out"
S --set LIVE_POLL_MS=2000 >"$WORK/out" 2>&1; rc=$?
check "secret in the file: another change is refused or leaves the line alone (value never echoed)" bash -c "! grep -qE 'hunter2|tokvalue77|sekret999|smtp-pass-1' '$WORK/out'"
S --unset DB_PASSWORD >/dev/null 2>&1; S --unset SETTINGS_ENCRYPTION_KEY >/dev/null 2>&1; S --unset SMTP_PASSWORD >/dev/null 2>&1
check "secret in the file: --unset deletes the line (no comment with the value)" bash -c "! grep -qE 'hunter2|sekret999|smtp-pass-1' '$ENVF'"

# ------------------------------------------------------------- --generate SETTINGS_ENCRYPTION_KEY
fresh
out="$(S --generate SETTINGS_ENCRYPTION_KEY 2>&1)"; rc=$?
check "generate: exit 0" eq "$rc" 0
check "generate: Swarm secret todo_settings_key was created" test -f "$WORK/secrets/todo_settings_key"
check "generate: the secret holds the key (44 base64 chars, no newline)" eq "$(cat "$WORK/secrets/todo_settings_key")" "$KEYVALUE"
check "generate: SETTINGS_KEY_ENABLED=true is in the env file" grep -qx 'SETTINGS_KEY_ENABLED=true' "$ENVF"
check "generate: the key is not in the env file or any backup" bash -c "! grep -rqF '$KEYVALUE' '$WORK/envdir'"
check "generate: the key is not in the output" bash -c "! grep -qF '$KEYVALUE' <<< \"\$1\"" _ "$out"
check "generate: the key never appears in a docker argument" bash -c "! grep -qF '$KEYVALUE' '$WORK/log.docker'"
check "generate: docker secret create reads stdin ('-')" grep -qx 'docker secret create todo_settings_key -' "$WORK/log.docker"
check "generate: openssl rand -base64 32 was used" grep -qx 'openssl rand -base64 32' "$WORK/log.openssl"
check "generate: output says the secret was created and the value is not shown" bash -c "grep -q 'angelegt' <<< \"\$1\" && grep -q 'nicht angezeigt' <<< \"\$1\"" _ "$out"
check "generate: output says nothing is rolled out" has "$out" "nicht ausgerollt"
check "generate: mode 0600 and a backup" bash -c "[ \"\$(stat -c '%a' '$ENVF' 2>/dev/null || stat -f '%Lp' '$ENVF')\" = 600 ] && ls '$ENVF'.bak.[0-9]*-[0-9]* >/dev/null"
check "generate: nothing was rolled out" nolines "$WORK/log.rollout"
check "generate: --get SETTINGS_ENCRYPTION_KEY still refuses" fails S --get SETTINGS_ENCRYPTION_KEY
: > "$WORK/log.docker"; : > "$WORK/log.openssl"; b="$(nbackups)"
out="$(S --generate SETTINGS_ENCRYPTION_KEY 2>&1)"; rc=$?
check "generate again: exit 0" eq "$rc" 0
check "generate again: says the secret exists and stays unchanged" bash -c "grep -q 'existiert schon' <<< \"\$1\" && grep -q 'unverändert' <<< \"\$1\"" _ "$out"
check "generate again: no second secret create" bash -c "! grep -q 'secret create' '$WORK/log.docker'"
check "generate again: no random value is even drawn" nolines "$WORK/log.openssl"
check "generate again: the stored key is unchanged" eq "$(cat "$WORK/secrets/todo_settings_key")" "$KEYVALUE"
check "generate again: the flag stays true without a new backup" bash -c "grep -qx 'SETTINGS_KEY_ENABLED=true' '$ENVF' && [ '$(nbackups)' = '$b' ]"
# an existing secret and no flag yet: only the flag is set
fresh; printf 'old-key-value' > "$WORK/secrets/todo_settings_key"
out="$(S --generate SETTINGS_ENCRYPTION_KEY 2>&1)"; rc=$?
check "generate (secret exists): sets only the flag" bash -c "[ $rc -eq 0 ] && grep -qx 'SETTINGS_KEY_ENABLED=true' '$ENVF' && ! grep -q 'secret create' '$WORK/log.docker' && [ \"\$(cat '$WORK/secrets/todo_settings_key')\" = old-key-value ]"
# custom secret name
fresh; printf 'SETTINGS_KEY_SECRET=my_custom_key\n' >> "$ENVF"
S --generate SETTINGS_ENCRYPTION_KEY >/dev/null 2>&1
check "generate: the secret name comes from SETTINGS_KEY_SECRET" test -f "$WORK/secrets/my_custom_key"
check "generate: ... and the default name is not touched" test ! -f "$WORK/secrets/todo_settings_key"
# failures change nothing
fresh; before="$(sha)"
STUB_DOCKER=down S --generate SETTINGS_ENCRYPTION_KEY >"$WORK/out" 2>&1; rc=$?
check "generate: Docker unreachable: error, nothing created, file unchanged" bash -c "[ $rc -ne 0 ] && [ '$(sha)' = '$before' ] && [ -z \"\$(ls '$WORK/secrets')\" ]"
STUB_SWARM=worker S --generate SETTINGS_ENCRYPTION_KEY >"$WORK/out" 2>&1; rc=$?
check "generate: not a swarm manager: error, nothing created" bash -c "[ $rc -ne 0 ] && [ '$(sha)' = '$before' ] && [ -z \"\$(ls '$WORK/secrets')\" ] && grep -qi 'manager' '$WORK/out'"
STUB_OPENSSL=fail S --generate SETTINGS_ENCRYPTION_KEY >"$WORK/out" 2>&1; rc=$?
check "generate: openssl fails: error, no (empty) secret created, file unchanged" bash -c "[ $rc -ne 0 ] && [ '$(sha)' = '$before' ] && [ -z \"\$(ls '$WORK/secrets')\" ]"
STUB_CREATE_FAIL=1 S --generate SETTINGS_ENCRYPTION_KEY >"$WORK/out" 2>&1; rc=$?
check "generate: docker secret create fails: error, flag not set" bash -c "[ $rc -ne 0 ] && [ '$(sha)' = '$before' ] && ! grep -qF '$KEYVALUE' '$WORK/out'"
rm -f "$WORK/envdir/none.env"
bash -c "cd '$DIR' && ./settings.sh --env '$WORK/envdir/none.env' --generate SETTINGS_ENCRYPTION_KEY" >"$WORK/out" 2>&1; rc=$?
check "generate: without an env file: error, no secret created" bash -c "[ $rc -ne 0 ] && [ -z \"\$(ls '$WORK/secrets')\" ] && [ ! -e '$WORK/envdir/none.env' ]"
check "generate: other keys are refused" bash -c "cd '$DIR' && ! ./settings.sh --env '$ENVF' --generate DB_PASSWORD >/dev/null 2>&1 && ! ./settings.sh --env '$ENVF' --generate INSTANCE_NAME >/dev/null 2>&1"
check "generate: nothing was rolled out in any case" nolines "$WORK/log.rollout"

# ------------------------------------------------------------- atomic write
fresh; before="$(sha)"
STUB_MV_FAIL=1 S --set LIVE_POLL_MS=2000 >"$WORK/out" 2>&1; rc=$?
check "atomic: a failing mv gives a non-zero exit" test "$rc" -ne 0
check "atomic: the env file is unchanged (no partial file)" eq "$(sha)" "$before"
check "atomic: no temp file is left in the directory" bash -c "! ls -A '$WORK/envdir' | grep -q '^\.settings'"
mvline="$(grep '^mv ' "$WORK/log.mv" | head -1)"; read -ra mvargs <<< "$mvline"
mvsrc="${mvargs[${#mvargs[@]}-2]:-}"; mvdst="${mvargs[${#mvargs[@]}-1]:-}"
check "atomic: the temp file is renamed onto the env file" eq "$mvdst" "$ENVF"
check "atomic: temp file and target share a directory (rename, not copy)" eq "$(dirname "$mvsrc")" "$(dirname "$ENVF")"
fresh; chmod 644 "$ENVF"
S --set LIVE_POLL_MS=2000 >/dev/null
check "atomic: a successful write sets mode 0600 even if the old file had 0644" eq "$(mode_of "$ENVF")" 600

# ------------------------------------------------------------- menu (whiptail stub)
# Flow: main menu (tag = group title) -> group (tag = KEY) -> input or choice; "1|" = back/Esc, an exhausted script = Esc.
fresh
menu '0|Pflichtangaben' '1|' '1|'
check "menu: the first group is Pflichtangaben" bash -c "grep -q 'RP_ORIGIN' '$WORK/log' && grep -q 'DB_HOST' '$WORK/log'"
check "menu: main menu offers Suchen, Hinweise, Schluessel, Speichern, Anwenden" hasall "$(call_n 1)" Suchen Hinweise Schluessel Speichern Anwenden
menu '0|Anmeldung' '0|PASSWORD_LOGIN_ENABLED' '0|true' '1|' '0|Speichern' '0|' '0|' '0|' '1|'
check "menu: a choice is saved (PASSWORD_LOGIN_ENABLED=true)" grep -qx 'PASSWORD_LOGIN_ENABLED=true' "$ENVF"
check "menu: the review shows the change and the effect" hasall "$(menutext)" "PASSWORD_LOGIN_ENABLED" "Jetzt anwenden"
check "menu: a backup was written" eq "$(nbackups)" 1
check "menu: saving rolled nothing out" nolines "$WORK/log.rollout"
fresh
menu '0|Live-Aktualisierung' '0|LIVE_POLL_MS' '0|abc' '0|' '0|2500' '1|' '0|Speichern' '0|' '0|' '0|' '1|'
check "menu: invalid input shows an error box and asks again" hasall "$(menutext)" "LIVE_POLL_MS" "ganze Zahl"
check "menu: the corrected value is saved" grep -qx 'LIVE_POLL_MS=2500' "$ENVF"
fresh; before="$(sha)"
menu '0|Live-Aktualisierung' '0|LIVE_POLL_MS' '0|2500' '1|' '1|' '0|V'
check "menu: discard on exit changes nothing" bash -c "[ '$(sha)' = '$before' ] && [ $MENU_RC -eq 0 ]"
fresh; before="$(sha)"
menu '0|E-Mail' '0|SMTP_PASSWORD' '0|' '1|' '1|'
check "menu: a secret setting shows a hint with docker secret, file unchanged" bash -c "grep -q 'docker secret create todo_smtp_password' '$WORK/log' && [ '$(sha)' = '$before' ]"
fresh
menu '0|Suchen' '0|stagger' '1|' '1|'
check "menu: search without hits says so" grep -q 'Keine Treffer' "$WORK/log"
menu '0|Suchen' '0|smtp' '0|SMTP_PORT' '1|' '1|' '1|' '1|'
check "menu: search finds SMTP_PORT" bash -c "grep -q 'SMTP_PORT' '$WORK/log' && ! grep -q 'script exhausted' '$WORK/log'"
# apply: only after confirmation
fresh
menu '0|Anwenden' '0|A' '1|' '1|'
check "apply: without confirmation nothing is rolled out" nolines "$WORK/log.rollout"
check "apply: the confirmation text names the database backup" grep -q 'Datenbank' "$WORK/log"
menu '0|Anwenden' '0|A' '0|' '1|'
check "apply: with confirmation update.sh runs with the env file, the current tag and --yes" bash -c "grep -q 'update.sh --env-file $ENVF --tag sha-abc1234 --force --yes' '$WORK/log.rollout'"
check "apply: exactly one roll-out call" eq "$(grep -c . "$WORK/log.rollout")" 1
menu '0|Anwenden' '0|D' '1|'
check "apply: the dry run calls update.sh --dry-run" grep -q -- '--dry-run' "$WORK/log.rollout"
fresh; sed -i.tmp '/^TODO_IMAGE_TAG=/d' "$ENVF"; rm -f "$ENVF.tmp"
menu '0|Anwenden' '0|A' '0|' '1|'
check "apply: without TODO_IMAGE_TAG in the file the stack default tag edge is used" grep -q -- '--tag edge ' "$WORK/log.rollout"
fresh; printf 'SYNC_RETENTION_DAYS=99999\n' >> "$ENVF"
menu '0|Anwenden' '0|' '1|'
check "apply: a file with errors is not rolled out" bash -c "[ ! -s '$WORK/log.rollout' ] && grep -q 'SYNC_RETENTION_DAYS' '$WORK/log'"
fresh; before="$(sha)"
menu '0|Live-Aktualisierung' '0|LIVE_POLL_MS' '0|2500' '1|' '0|Anwenden' '1|' '1|' '0|V'
check "apply: unsaved changes: declining 'save first' rolls nothing out and writes nothing" bash -c "[ ! -s '$WORK/log.rollout' ] && [ '$(sha)' = '$before' ] && grep -q 'ungespeicherte' '$WORK/log'"
# key via menu
fresh
menu '0|Schluessel' '0|' '1|' '1|'
check "menu: Schluessel with confirmation creates the secret and sets the flag" bash -c "test -f '$WORK/secrets/todo_settings_key' && grep -qx 'SETTINGS_KEY_ENABLED=true' '$ENVF'"
check "menu: the key is shown nowhere (log, output, env directory)" bash -c "! grep -rqF '$KEYVALUE' '$WORK/log' '$WORK/menu.out' '$WORK/envdir'"
check "menu: creating the key rolled nothing out" nolines "$WORK/log.rollout"
fresh; menu '0|Schluessel' '1|' '1|'
check "menu: Schluessel declined: nothing created" bash -c "[ -z \"\$(ls '$WORK/secrets')\" ] && ! grep -q SETTINGS_KEY_ENABLED '$ENVF'"
# no whiptail/dialog
fresh
nowt="$WORK/nowt"; mkdir -p "$nowt"; ln -sf "$(command -v bash)" "$nowt/bash"
for t in env dirname cat awk sed sort tr date cp chmod mktemp rm timeout readlink diff tail head grep cut wc ls id stat mv uname basename tput stty sleep; do
  p="$(PATH="${PATH#"$WORK/bin:"}" command -v "$t" 2>/dev/null)"; [ -n "$p" ] && ln -sf "$p" "$nowt/$t"
done
out="$( cd "$DIR" && PATH="$nowt" "$nowt/bash" ./settings.sh --env "$ENVF" 2>&1 )"; rc=$?
check "no whiptail/dialog: clear message, exit 1" bash -c "[ $rc -eq 1 ] && grep -q 'whiptail' <<< \"\$1\"" _ "$out"
out="$( cd "$DIR" && PATH="$nowt" "$nowt/bash" ./settings.sh --env "$ENVF" --list 2>&1 )"; rc=$?
check "no whiptail/dialog: the CLI still works" eq "$rc" 0

# ------------------------------------------------------------- Bash version
out="$(cd "$DIR" && SETTINGS_TEST_BASH_VERSION=4.3.48 ./settings.sh --env "$ENVF" --list 2>&1)"; rc=$?
check "bash: version 4.3 is refused (exit 1) with a message" bash -c "[ $rc -eq 1 ] && grep -q 'Bash 4.4' <<< \"\$1\"" _ "$out"
out="$(cd "$DIR" && SETTINGS_TEST_BASH_VERSION=3.2.57 ./settings.sh --env "$ENVF" --list 2>&1)"; rc=$?
check "bash: version 3.2 is refused (exit 1)" eq "$rc" 1
check "bash: version 4.4 is accepted" bash -c "cd '$DIR' && SETTINGS_TEST_BASH_VERSION=4.4.0 ./settings.sh --env '$ENVF' --list >/dev/null 2>&1"
check "bash: version 5.2 is accepted" bash -c "cd '$DIR' && SETTINGS_TEST_BASH_VERSION=5.2.21 ./settings.sh --env '$ENVF' --list >/dev/null 2>&1"
if [ -x /bin/bash ] && /bin/bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ]' 2>/dev/null; then
  out="$(cd "$DIR" && /bin/bash ./settings.sh --env "$ENVF" --list 2>&1)"; rc=$?
  check "bash: the real old /bin/bash is refused with a clear message" bash -c "[ $rc -eq 1 ] && grep -q 'Bash 4.4' <<< \"\$1\"" _ "$out"
fi

# ------------------------------------------------------------- repository consistency
check "repo: config-registry.tsv is present (generated by SettingsRegistryTSVTests)" test -s "$SRC/config-registry.tsv"
check "repo: every non-comment row has 11 columns" bash -c "awk -F'\t' '!/^#/ && NF != 11 { bad = 1 } END { exit bad }' '$SRC/config-registry.tsv' '$SRC/config-extra.tsv'"
check "repo: settings.sh passes bash -n" bash -n "$SRC/settings.sh"
check "repo: the shipped stack.env.example passes --check against the shipped tables" bash -c "cd '$DIR' && cp stack.env.example '$WORK/tpl.env' && chmod 600 '$WORK/tpl.env' && ./settings.sh --env '$WORK/tpl.env' --check >/dev/null 2>&1"

echo "---- $total checks, $fail failed"
[ "$fail" = 0 ]
