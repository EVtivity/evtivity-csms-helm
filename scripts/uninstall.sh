#!/usr/bin/env bash
set -euo pipefail

RELEASE="evtivity"
NAMESPACE="evtivity"

read -rp "Uninstall '$RELEASE' (including PostgreSQL and Redis) from namespace '$NAMESPACE'? (y/n) " confirm

if [ "$confirm" != "y" ]; then
  echo "Aborted."
  exit 1
fi

helm uninstall "$RELEASE" --namespace "$NAMESPACE" 2>/dev/null || echo "Release '$RELEASE' not found, skipping."
helm uninstall "${RELEASE}-postgresql" --namespace "$NAMESPACE" 2>/dev/null || echo "Release '${RELEASE}-postgresql' not found, skipping."
helm uninstall "${RELEASE}-redis" --namespace "$NAMESPACE" 2>/dev/null || echo "Release '${RELEASE}-redis' not found, skipping."

kubectl delete jobs -l app.kubernetes.io/component=migrate -n "$NAMESPACE" 2>/dev/null || true
kubectl delete secret "${RELEASE}-css-tls" -n "$NAMESPACE" 2>/dev/null || true

echo ""
echo "Uninstalled all releases from $NAMESPACE."

read -rp "Delete persistent volume claims (all data will be lost)? (y/n) " delete_pvcs

if [ "$delete_pvcs" = "y" ]; then
  kubectl delete pvc --all -n "$NAMESPACE" 2>/dev/null || echo "No PVCs found."
  echo "Deleted all PVCs from $NAMESPACE."
fi
