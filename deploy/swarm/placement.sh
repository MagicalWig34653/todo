#!/usr/bin/env bash
# Placement helpers for scripts/swarm-deploy.sh. Source this file, do not execute it.
#
# Optional environment variables (all empty by default = current behaviour, no overlay):
#   PLACEMENT_CONSTRAINTS  comma separated Swarm constraints for backend and migrate, e.g. "node.role==worker,node.labels.zone!=dev"
#   PLACEMENT_PREFERENCES  comma separated spread keys for backend and migrate, e.g. "node.labels.zone"
#   EXCLUDE_LABEL          node label name; nodes with <label>=true get no backend/migrate task (does NOT apply to backend-pinned)
#   PINNED_NODE            hostname of a node that runs the extra service backend-pinned
#   PINNED_REPLICAS        replicas of backend-pinned (default 1, only used when PINNED_NODE is set)
#   BACKEND_PINNED_PORT    optional extra published port for backend-pinned (default: none)
#
# placement_prepare OVERLAY_FILE validates the variables, exports BACKEND_PINNED_EFFECTIVE_REPLICAS and
# BACKEND_PINNED_CONSTRAINT (both are read by stack.yaml) and writes a compose overlay to OVERLAY_FILE.
# Return codes: 0 = overlay written (pass it with -c), 1 = nothing to overlay (file left empty), 2 = invalid input (message on stderr).
# Compose cannot split comma lists, therefore the overlay is generated.

_placement_err() { printf 'placement: %s\n' "$*" >&2; }
_placement_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# Prints the normalised constraint ("key==value") or fails.
_placement_constraint() {
  local c key op val
  c="$(_placement_trim "$1")"
  if [[ "$c" =~ ^([A-Za-z][A-Za-z0-9_.-]*)[[:space:]]*(==|!=)[[:space:]]*([A-Za-z0-9_][A-Za-z0-9_.:/@-]*)$ ]]; then
    key="${BASH_REMATCH[1]}"; op="${BASH_REMATCH[2]}"; val="${BASH_REMATCH[3]}"
  else
    _placement_err "invalid constraint '$c' (expected <key>==<value> or <key>!=<value>)"; return 1
  fi
  case "$key" in
    node.id|node.hostname|node.role|node.platform.os|node.platform.arch) ;;
    node.labels.?*|engine.labels.?*) ;;
    *) _placement_err "unsupported constraint key '$key' (node.id, node.hostname, node.role, node.platform.os, node.platform.arch, node.labels.*, engine.labels.*)"; return 1 ;;
  esac
  printf '%s %s %s' "$key" "$op" "$val"
}

placement_prepare() {
  local out="$1" item norm n_constraints=0 n_prefs=0 pinned_replicas
  local -a constraints=() prefs=()
  PLACEMENT_CONSTRAINTS="${PLACEMENT_CONSTRAINTS:-}"; PLACEMENT_PREFERENCES="${PLACEMENT_PREFERENCES:-}"
  EXCLUDE_LABEL="${EXCLUDE_LABEL:-}"; PINNED_NODE="${PINNED_NODE:-}"; PINNED_REPLICAS="${PINNED_REPLICAS:-}"
  BACKEND_PINNED_PORT="${BACKEND_PINNED_PORT:-}"
  : > "$out"

  if [[ -n "$PLACEMENT_CONSTRAINTS" ]]; then
    local IFS=','
    for item in $PLACEMENT_CONSTRAINTS; do
      [[ -n "$(_placement_trim "$item")" ]] || { _placement_err "empty entry in PLACEMENT_CONSTRAINTS"; return 2; }
      norm="$(_placement_constraint "$item")" || return 2
      constraints+=("$norm")
    done
    unset IFS
  fi
  if [[ -n "$EXCLUDE_LABEL" ]]; then
    [[ "$EXCLUDE_LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { _placement_err "invalid EXCLUDE_LABEL '$EXCLUDE_LABEL'"; return 2; }
    constraints+=("node.labels.${EXCLUDE_LABEL} != true")
  fi
  if [[ -n "$PLACEMENT_PREFERENCES" ]]; then
    local IFS=','
    for item in $PLACEMENT_PREFERENCES; do
      item="$(_placement_trim "$item")"
      [[ "$item" =~ ^(node|engine)\.labels\.[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { _placement_err "invalid preference '$item' (expected node.labels.<name> or engine.labels.<name>)"; return 2; }
      prefs+=("$item")
    done
    unset IFS
  fi

  # Pinned service: always exported, so stack.yaml can scale it to 0 again when PINNED_NODE is removed.
  if [[ -n "$PINNED_NODE" ]]; then
    [[ "$PINNED_NODE" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { _placement_err "invalid PINNED_NODE '$PINNED_NODE'"; return 2; }
    pinned_replicas="${PINNED_REPLICAS:-1}"
    [[ "$pinned_replicas" =~ ^[0-9]{1,2}$ ]] || { _placement_err "invalid PINNED_REPLICAS '$pinned_replicas' (0-99)"; return 2; }
    export BACKEND_PINNED_EFFECTIVE_REPLICAS="$pinned_replicas"
    export BACKEND_PINNED_CONSTRAINT="node.hostname == ${PINNED_NODE}"
  else
    export BACKEND_PINNED_EFFECTIVE_REPLICAS=0
    export BACKEND_PINNED_CONSTRAINT="node.hostname == __no-pinned-node__"
  fi
  if [[ -n "$BACKEND_PINNED_PORT" ]]; then
    [[ -n "$PINNED_NODE" ]] || { _placement_err "BACKEND_PINNED_PORT needs PINNED_NODE"; return 2; }
    [[ "$BACKEND_PINNED_PORT" =~ ^[0-9]{1,5}$ ]] && (( BACKEND_PINNED_PORT >= 1 && BACKEND_PINNED_PORT <= 65535 )) \
      || { _placement_err "invalid BACKEND_PINNED_PORT '$BACKEND_PINNED_PORT'"; return 2; }
    [[ "$BACKEND_PINNED_PORT" != "${BACKEND_PORT:-38080}" ]] || { _placement_err "BACKEND_PINNED_PORT must differ from BACKEND_PORT"; return 2; }
  fi

  n_constraints=${#constraints[@]}; n_prefs=${#prefs[@]}
  [[ $n_constraints -gt 0 || $n_prefs -gt 0 || -n "$BACKEND_PINNED_PORT" ]] || return 1

  {
    echo "version: '3.8'"
    echo "# Generated by deploy/swarm/placement.sh - do not edit."
    echo "services:"
    if [[ $n_constraints -gt 0 || $n_prefs -gt 0 ]]; then
      for svc in migrate backend; do
        echo "  ${svc}:"
        echo "    deploy:"
        echo "      placement:"
        if [[ $n_constraints -gt 0 ]]; then
          echo "        constraints:"
          for item in "${constraints[@]}"; do echo "          - \"${item}\""; done
        fi
        if [[ $n_prefs -gt 0 ]]; then
          echo "        preferences:"
          for item in "${prefs[@]}"; do echo "          - spread: ${item}"; done
        fi
      done
    fi
    if [[ -n "$BACKEND_PINNED_PORT" ]]; then
      echo "  backend-pinned:"
      echo "    ports:"
      echo "      - target: 8080"
      echo "        published: ${BACKEND_PINNED_PORT}"
      echo "        protocol: tcp"
      echo "        mode: ingress"
    fi
  } > "$out"
  return 0
}
