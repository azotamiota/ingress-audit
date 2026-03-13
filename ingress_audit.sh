#!/bin/bash

set -euo pipefail

# ------------------------------------------------------------------------------
# Audits ingress objects across all namespaces and classifies them into:
#   FLAGGED  - namespaces with ingresses but NO -traefik paired counterparts
#   DONE     - namespaces where every non-traefik ingress has a -traefik pair
# ------------------------------------------------------------------------------

FLAGGED_NAMESPACES=()
DONE_NAMESPACES=()

log()    { echo "[INFO]  $*"; }
warn()   { echo "[WARN]  $*"; }
header() { echo; echo "========== $* =========="; }

# ------------------------------------------------------------------------------
# 1. Collect all namespaces
# ------------------------------------------------------------------------------
header "Fetching namespaces"
mapfile -t NAMESPACES < <(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')
log "Found ${#NAMESPACES[@]} namespace(s): ${NAMESPACES[*]}"

# ------------------------------------------------------------------------------
# 2. Loop through each namespace
# ------------------------------------------------------------------------------
for ns in "${NAMESPACES[@]}"; do
  header "Namespace: $ns"
  kubens "$ns" > /dev/null 2>&1

  # --- Fetch ingress names; skip namespace if none exist ---
  mapfile -t INGRESSES < <(kubectl get ingress -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' || true)

  if [[ ${#INGRESSES[@]} -eq 0 ]]; then
    log "No ingress objects found — skipping."
    continue
  fi

  log "Found ${#INGRESSES[@]} ingress(es): ${INGRESSES[*]}"

  # --- Split into traefik and non-traefik ingresses ---
  traefik_ingresses=()
  base_ingresses=()

  for ing in "${INGRESSES[@]}"; do
    if [[ "$ing" == *"-traefik" ]]; then
      traefik_ingresses+=("$ing")
    else
      base_ingresses+=("$ing")
    fi
  done

  log "Base ingresses     : ${base_ingresses[*]:-<none>}"
  log "Traefik ingresses  : ${traefik_ingresses[*]:-<none>}"

  # --- Option 1: No -traefik ingresses at all → FLAGGED ---
  if [[ ${#traefik_ingresses[@]} -eq 0 ]]; then
    warn "No -traefik ingresses found → marking as FLAGGED."
    FLAGGED_NAMESPACES+=("$ns")
    continue
  fi

  # --- Option 2: Mix of traefik and non-traefik ingresses ---
  # Check every base ingress has a matching <name>-traefik counterpart
  all_paired=true
  unpaired=()

  for base_ing in "${base_ingresses[@]}"; do
    expected_pair="${base_ing}-traefik"
    if printf '%s\n' "${traefik_ingresses[@]}" | grep -qx "$expected_pair"; then
      log "  ✔  '$base_ing' → paired with '$expected_pair'"
    else
      warn "  ✘  '$base_ing' → NO pair '$expected_pair' found"
      all_paired=false
      unpaired+=("$base_ing")
    fi
  done

  if $all_paired; then
    log "All base ingresses are fully paired → marking as DONE."
    DONE_NAMESPACES+=("$ns")
  else
    warn "Unpaired base ingresses (${unpaired[*]}) → marking as FLAGGED."
    FLAGGED_NAMESPACES+=("$ns")
  fi
done

# ------------------------------------------------------------------------------
# 3. Final report
# ------------------------------------------------------------------------------
header "AUDIT SUMMARY"

echo
echo "--- FLAGGED (missing -traefik pairs) [${#FLAGGED_NAMESPACES[@]}] ---"
if [[ ${#FLAGGED_NAMESPACES[@]} -gt 0 ]]; then
  printf '  • %s\n' "${FLAGGED_NAMESPACES[@]}"
else
  echo "  (none)"
fi

echo
echo "--- DONE (all pairs present) [${#DONE_NAMESPACES[@]}] ---"
if [[ ${#DONE_NAMESPACES[@]} -gt 0 ]]; then
  printf '  • %s\n' "${DONE_NAMESPACES[@]}"
else
  echo "  (none)"
fi

echo


# ------------------------------------------------------------------------------
# 4. Write report to file named after the current cluster
# ------------------------------------------------------------------------------
CLUSTER_NAME=$(kubectl config current-context)
REPORT_FILE="${CLUSTER_NAME}-ingress-audit-$(date +%Y-%m-%d).txt"

{
  echo "Ingress Audit Report"
  echo "Cluster  : ${CLUSTER_NAME}"
  echo "Date     : $(date)"
  echo

  echo "--- FLAGGED (missing -traefik pairs) [${#FLAGGED_NAMESPACES[@]}] ---"
  if [[ ${#FLAGGED_NAMESPACES[@]} -gt 0 ]]; then
    printf '  • %s\n' "${FLAGGED_NAMESPACES[@]}"
  else
    echo "  (none)"
  fi

  echo
  echo "--- DONE (all pairs present) [${#DONE_NAMESPACES[@]}] ---"
  if [[ ${#DONE_NAMESPACES[@]} -gt 0 ]]; then
    printf '  • %s\n' "${DONE_NAMESPACES[@]}"
  else
    echo "  (none)"
  fi
} > "$REPORT_FILE"

log "Report written to: $REPORT_FILE"
