#!/usr/bin/env bash
# Tests deploy/swarm/placement.sh and the stack files. No Swarm needed: only bash and `docker compose config` (optional).
set -u
cd "$(dirname "$0")/../deploy/swarm" || exit 2
. ./placement.sh
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
run() { # name expected_rc env... (runs placement_prepare in a subshell)
  local name="$1" want="$2"; shift 2
  local rc; ( env -i PATH="$PATH" "$@" bash -c '. ./placement.sh; placement_prepare "$0"; rc=$?; echo "$BACKEND_PINNED_EFFECTIVE_REPLICAS|$BACKEND_PINNED_CONSTRAINT" >"$0.vars"; exit $rc' "$tmp/o" 2>"$tmp/err" ); rc=$?
  [[ $rc == "$want" ]] && ok "$name (rc $rc)" || { bad "$name (rc $rc, wanted $want): $(cat "$tmp/err")"; }
}
run "nothing set" 1
[[ ! -s $tmp/o ]] && ok "no overlay when nothing set" || bad "overlay not empty"
[[ $(cat "$tmp/o.vars") == "0|node.hostname == __no-pinned-node__" ]] && ok "pinned defaults to 0" || bad "pinned defaults: $(cat "$tmp/o.vars")"
run "constraints" 0 PLACEMENT_CONSTRAINTS="node.role==worker, node.labels.zone != dev"
grep -q '"node.role == worker"' "$tmp/o" && grep -q '"node.labels.zone != dev"' "$tmp/o" && ok "constraints normalised" || bad "constraints content"
run "preferences" 0 PLACEMENT_PREFERENCES="node.labels.zone,node.labels.rack"
grep -q 'spread: node.labels.rack' "$tmp/o" && ok "preferences" || bad "preferences content"
run "exclude label" 0 EXCLUDE_LABEL=noapi
grep -q 'node.labels.noapi != true' "$tmp/o" && ok "exclude label" || bad "exclude content"
grep -q 'backend-pinned' "$tmp/o" && bad "exclude must not touch backend-pinned" || ok "exclude leaves backend-pinned alone"
run "pinned node only" 1 PINNED_NODE=node-2
[[ $(cat "$tmp/o.vars") == "1|node.hostname == node-2" ]] && ok "pinned default 1 replica" || bad "pinned vars: $(cat "$tmp/o.vars")"
run "pinned replicas 0" 1 PINNED_NODE=node-2 PINNED_REPLICAS=0
[[ $(cat "$tmp/o.vars") == "0|node.hostname == node-2" ]] && ok "pinned replicas 0" || bad "pinned replicas 0"
run "replicas without node" 1 PINNED_REPLICAS=3
[[ $(cat "$tmp/o.vars") == 0* ]] && ok "no node -> 0 replicas" || bad "replicas without node"
run "pinned port" 0 PINNED_NODE=n1 BACKEND_PINNED_PORT=38081
grep -A5 'backend-pinned' "$tmp/o" | grep -q 'published: 38081' && ok "pinned port overlay" || bad "pinned port content"
run "port without node" 2 BACKEND_PINNED_PORT=38081
run "port equals BACKEND_PORT" 2 PINNED_NODE=n1 BACKEND_PINNED_PORT=38080
run "bad constraint" 2 PLACEMENT_CONSTRAINTS="node.role=worker"
run "bad constraint key" 2 PLACEMENT_CONSTRAINTS="foo.bar==x"
run "injection" 2 PLACEMENT_CONSTRAINTS='node.role==x"; evil'
run "empty entry" 2 PLACEMENT_CONSTRAINTS="node.role==worker,,node.role==manager"
run "bad preference" 2 PLACEMENT_PREFERENCES="zone"
run "bad label" 2 EXCLUDE_LABEL='a b'
run "bad node" 2 PINNED_NODE='n 1'
run "bad replicas" 2 PINNED_NODE=n1 PINNED_REPLICAS=x
# Overlay copies: without PINNED_NODE the feature overlays lose their backend-pinned lines.
for f in stack.s3.yaml stack.push.yaml stack.mail.yaml stack.settings.yaml stack.settings-previous.yaml; do
  ( env -i PATH="$PATH" bash -c '. ./placement.sh; placement_overlay_copy "$0" "$1"' "$f" "$tmp/c" )
  { ! grep -q 'backend-pinned' "$tmp/c" && grep -q 'backend: ' "$tmp/c"; } && ok "$f copy: no backend-pinned without PINNED_NODE" || bad "$f copy without node"
  ( env -i PATH="$PATH" PINNED_NODE=n1 bash -c '. ./placement.sh; placement_overlay_copy "$0" "$1"' "$f" "$tmp/c" )
  cmp -s "$f" "$tmp/c" && ok "$f copy: unchanged with PINNED_NODE" || bad "$f copy with node"
done
if grep -v '^ *#' stack.yaml | grep -q 'backend-pinned'; then bad "stack.yaml must not define backend-pinned"; else ok "stack.yaml has no backend-pinned service"; fi
# stack.pinned.yaml repeats the x-backend / x-backend-deploy blocks of stack.yaml: they must stay identical.
blocks() { awk '/^x-backend/ {p=1} /^services:/ {p=0} p' "$1" | grep -v '^ *#'; }
if [[ -n "$(blocks stack.pinned.yaml)" && "$(blocks stack.yaml)" == "$(blocks stack.pinned.yaml)" ]]; then ok "stack.pinned.yaml x-backend blocks match stack.yaml"; else bad "x-backend blocks drifted between stack.yaml and stack.pinned.yaml"; fi
# guard / cleanup with a fake docker: STUB_PINNED = replicas of an existing service, unset = service does not exist.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$1 $2" in
  "service inspect") if [[ -n "${STUB_PINNED:-}" ]]; then echo "$STUB_PINNED"; else exit 1; fi ;;
  "service rm") ;;
  *) exit 9 ;;
esac
STUB
chmod +x "$tmp/bin/docker"
pin() { # name fn expected_rc expected_rm(0/1) env...
  local name="$1" fn="$2" want="$3" rm_want="$4"; shift 4
  : > "$tmp/log"; local rc
  ( env -i PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/log" "$@" bash -c ". ./placement.sh; $fn todo" >"$tmp/out" 2>"$tmp/err" ); rc=$?
  local rm_got=0; grep -q '^service rm todo_backend-pinned' "$tmp/log" && rm_got=1
  [[ $rc == "$want" && $rm_got == "$rm_want" ]] && ok "$name" || bad "$name (rc $rc wanted $want, rm $rm_got wanted $rm_want)"
}
pin "cleanup: no service, no node -> nothing" placement_pinned_cleanup 0 0
pin "cleanup: empty old service, no node -> removed" placement_pinned_cleanup 0 1 STUB_PINNED=0
pin "cleanup: running old service, no node -> kept, error" placement_pinned_cleanup 1 0 STUB_PINNED=2
pin "cleanup: PINNED_NODE set -> service kept" placement_pinned_cleanup 0 0 STUB_PINNED=0 PINNED_NODE=n1
pin "guard: no service -> ok" placement_pinned_guard 0 0
pin "guard: empty old service -> ok" placement_pinned_guard 0 0 STUB_PINNED=0
pin "guard: running old service, no node -> error" placement_pinned_guard 1 0 STUB_PINNED=1
grep -q 'docker service scale todo_backend-pinned=0' "$tmp/err" && ok "guard: error names the way out" || bad "guard message"
pin "guard: PINNED_NODE set -> ok" placement_pinned_guard 0 0 STUB_PINNED=1 PINNED_NODE=n1
# Compose rendering (skipped without docker compose). Mirrors scripts/swarm-deploy.sh: stack.pinned.yaml only with PINNED_NODE.
if docker compose version >/dev/null 2>&1; then
  render() { env -i PATH="$PATH" HOME="$HOME" DB_HOST=db "$@" bash -c '. ./placement.sh; d=$(mktemp -d); placement_prepare "$d/p"; rc=$?; args=(-f stack.yaml)
    if [ -n "$PINNED_NODE" ]; then args+=(-f stack.pinned.yaml); fi
    placement_overlay_copy stack.settings.yaml "$d/s.yaml"; args+=(-f "$d/s.yaml")
    [ $rc = 0 ] && args+=(-f "$d/p"); docker compose "${args[@]}" config 2>&1; rm -rf "$d"'; }
  out=$(render); if grep -q '^  backend-pinned:' <<<"$out"; then bad "compose: default must not contain backend-pinned"; else ok "compose: no backend-pinned without PINNED_NODE"; fi
  grep -q '^  backend:' <<<"$out" && grep -q '^  migrate:' <<<"$out" && ok "compose: backend and migrate still present" || bad "compose default services"
  out=$(render PINNED_NODE=node-2 PLACEMENT_CONSTRAINTS=node.role==worker EXCLUDE_LABEL=noapi PLACEMENT_PREFERENCES=node.labels.zone)
  grep -A60 '^  backend-pinned:' <<<"$out" | grep -q 'node.hostname == node-2' && ok "compose: pinned constraint" || bad "compose pinned constraint"
  grep -A60 '^  backend-pinned:' <<<"$out" | grep -q 'replicas: 1' && ok "compose: pinned 1 replica" || bad "compose pinned replicas"
  grep -A60 '^  backend-pinned:' <<<"$out" | grep -q 'settings_key' && ok "compose: feature overlay reaches backend-pinned" || bad "compose pinned overlay"
  [[ $(grep -c 'node.labels.noapi != true' <<<"$out") == 2 ]] && ok "compose: exclude on backend and migrate only" || bad "compose exclude count"
  grep -q 'spread: node.labels.zone' <<<"$out" && ok "compose: preference" || bad "compose preference"
  out=$(render PINNED_NODE=node-2 PINNED_REPLICAS=0)
  grep -A60 '^  backend-pinned:' <<<"$out" | grep -q 'replicas: 0' && ok "compose: PINNED_REPLICAS=0 keeps the service with 0" || bad "compose pinned 0"
  out=$(render PINNED_NODE=node-2 BACKEND_PINNED_PORT=38081)
  grep -A80 '^  backend-pinned:' <<<"$out" | grep -q 'published: "38081"' && ok "compose: pinned port" || bad "compose pinned port"
else echo "skip docker compose rendering (not installed)"; fi
exit $fail
