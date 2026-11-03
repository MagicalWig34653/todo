#!/usr/bin/env bash
# Tests deploy/swarm/placement.sh and the stack files. No Swarm needed: only bash and `docker compose config` (optional).
set -u
cd "$(dirname "$0")/../deploy/swarm"
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
# Compose rendering (skipped without docker compose).
if docker compose version >/dev/null 2>&1; then
  render() { env -i PATH="$PATH" HOME="$HOME" DB_HOST=db "$@" bash -c '. ./placement.sh; o=$(mktemp); placement_prepare "$o"; rc=$?; args=(-f stack.yaml); [ $rc = 0 ] && args+=(-f "$o"); docker compose "${args[@]}" config 2>/dev/null; rm -f "$o"'; }
  out=$(render); grep -A40 '^  backend-pinned:' <<<"$out" | grep -q 'replicas: 0' && ok "compose: pinned 0 replicas by default" || bad "compose default"
  out=$(render PINNED_NODE=node-2 PLACEMENT_CONSTRAINTS=node.role==worker EXCLUDE_LABEL=noapi PLACEMENT_PREFERENCES=node.labels.zone)
  grep -A60 '^  backend-pinned:' <<<"$out" | grep -q 'node.hostname == node-2' && ok "compose: pinned constraint" || bad "compose pinned constraint"
  [[ $(grep -c 'node.labels.noapi != true' <<<"$out") == 2 ]] && ok "compose: exclude on backend and migrate only" || bad "compose exclude count"
  grep -q 'spread: node.labels.zone' <<<"$out" && ok "compose: preference" || bad "compose preference"
else echo "skip docker compose rendering (not installed)"; fi
exit $fail
