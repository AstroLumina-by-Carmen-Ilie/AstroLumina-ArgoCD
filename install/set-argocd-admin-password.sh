#!/usr/bin/env bash
# Set the ArgoCD admin password from a pre-hashed bcrypt value in Doppler.
#
# Doppler holds the bcrypt hash in ARGOCD_ADMIN_PASSWORD_HASH (preferred) or
# ARGOCD_ADMIN_PASSWORD (project astrolumina, config prd by default) --
# either way the value must be ONLY the hash, never the plaintext password.
# Generate it with: htpasswd -nbB admin  (paste the hash part after "admin:").
# The same htpasswd line used for Prometheus basic-auth works here too; an
# optional "user:" prefix is stripped automatically.
#
# The script validates the hash format locally, normalizes a $2y$ prefix to
# $2b$ (functionally identical; $2b$ is what ArgoCD's Go bcrypt expects), then
# patches only the two password keys of the `argocd-secret` Secret. No hashing
# happens here and no secret material is written to disk anywhere.
#
# After patching it deletes `argocd-initial-admin-secret` (so the UI stops
# advertising the throwaway password) and restarts argocd-server to pick up
# the new hash. Safe to re-run for rotation.
#
# Requirements on this laptop: doppler CLI (logged in), python3, ssh access
# via K8S_CP_CONN. The argocd Helm release must already be installed (the
# script waits for argocd-server to be ready).
#
# Usage:
#   export K8S_CP_CONN=$(doppler secrets get K8S_CP_CONN --plain --project astrolumina --config prd)
#   ./install/set-argocd-admin-password.sh
#
# Optional overrides:
#   DOPPLER_PROJECT / DOPPLER_CONFIG - where the hash lives (default: astrolumina/prd)
#   ARGOCD_RELEASE                   - Helm release name (default: argocd; secret is <release>-secret)
set -euo pipefail

: "${K8S_CP_CONN:?K8S_CP_CONN must be exported (ssh destination of the control plane).}"
DOPPLER_PROJECT="${DOPPLER_PROJECT:-astrolumina}"
DOPPLER_CONFIG="${DOPPLER_CONFIG:-prd}"
ARGOCD_RELEASE="${ARGOCD_RELEASE:-argocd}"
SECRET_NAME="${ARGOCD_RELEASE}-secret"
SERVER_DEPLOY="${ARGOCD_RELEASE}-server"

command -v doppler >/dev/null || { echo "ERROR: doppler CLI not found on this laptop." >&2; exit 1; }

echo "Reading ArgoCD admin hash from Doppler (${DOPPLER_PROJECT}/${DOPPLER_CONFIG})..."
HASH_VALUE="$(doppler secrets get ARGOCD_ADMIN_PASSWORD_HASH --plain --project "$DOPPLER_PROJECT" --config "$DOPPLER_CONFIG" 2>/dev/null || true)"
if [ -z "$HASH_VALUE" ]; then
  # Fallback to the plainly-named variable (it may hold the same hash value).
  HASH_VALUE="$(doppler secrets get ARGOCD_ADMIN_PASSWORD --plain --project "$DOPPLER_PROJECT" --config "$DOPPLER_CONFIG")"
fi
if [ -z "$HASH_VALUE" ]; then
  echo "ERROR: neither ARGOCD_ADMIN_PASSWORD_HASH nor ARGOCD_ADMIN_PASSWORD is set in Doppler ${DOPPLER_PROJECT}/${DOPPLER_CONFIG}." >&2
  exit 1
fi

echo "Waiting for ${SERVER_DEPLOY} to be ready..."
ssh "$K8S_CP_CONN" -- "kubectl rollout status deploy/${SERVER_DEPLOY} -n argocd --timeout=300s"

# Validate the hash shape with python (a full bcrypt string is 60 chars:
# $2a|b|y$ + cost + 53 chars of salt+hash). Accepts an optional "user:" prefix
# so a verbatim htpasswd -nB line can be pasted into Doppler. Normalizes $2y$
# to $2b$ on the way out. The merge patch touches ONLY the password keys.
PATCH_FILE="$(mktemp)"
trap 'rm -f "$PATCH_FILE"' EXIT
MTIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HASH_VALUE="$HASH_VALUE" MTIME="$MTIME" python3 - "$PATCH_FILE" <<'EOF'
import json
import os
import re
import sys

value = os.environ["HASH_VALUE"].strip()
if ":" in value:
    value = value.split(":", 1)[1].strip()
if not re.fullmatch(r"\$2[aby]\$\d{2}\$[./A-Za-z0-9]{53}", value):
    print("ERROR: value is not a valid bcrypt hash (expected $2a$/$2b$/$2y$ + cost + 53 chars).", file=sys.stderr)
    sys.exit(1)
password_hash = value.replace("$2y$", "$2b$", 1)
patch = {
    "stringData": {
        "admin.password": password_hash,
        "admin.passwordMtime": os.environ["MTIME"],
    }
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(patch, handle)
EOF

echo "Patching ${SECRET_NAME} (password keys only), removing the initial-password secret, restarting the server..."
cat "$PATCH_FILE" | ssh "$K8S_CP_CONN" -- 'kubectl patch secret '"$SECRET_NAME"' -n argocd --type merge -p "$(cat)" && kubectl delete secret argocd-initial-admin-secret -n argocd --ignore-not-found && kubectl rollout restart deploy/'"$SERVER_DEPLOY"' -n argocd && kubectl rollout status deploy/'"$SERVER_DEPLOY"' -n argocd --timeout=300s'

echo "Done. Log in as admin with the plaintext password behind the Doppler hash (${DOPPLER_PROJECT}/${DOPPLER_CONFIG})."
