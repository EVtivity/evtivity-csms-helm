#!/usr/bin/env bash
set -euo pipefail

RELEASE="evtivity"
NAMESPACE="evtivity"
CHART_DIR="$(cd "$(dirname "$0")/.." && pwd)"

generate_secret() {
  openssl rand -base64 32 | tr -d '/+=' | cut -c1-32
}

POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(generate_secret)}"
REDIS_PASSWORD="${REDIS_PASSWORD:-$(generate_secret)}"
JWT_SECRET="${JWT_SECRET:-$(generate_secret)}"
SETTINGS_ENCRYPTION_KEY="${SETTINGS_ENCRYPTION_KEY:-$(generate_secret)}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(generate_secret)}"

POSTGRES_HOST="${POSTGRES_HOST:-${RELEASE}-postgresql}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-evtivity}"
POSTGRES_USER="${POSTGRES_USER:-evtivity}"
REDIS_HOST="${REDIS_HOST:-${RELEASE}-redis-master}"
REDIS_PORT="${REDIS_PORT:-6379}"

DATABASE_URL="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
REDIS_URL="redis://default:${REDIS_PASSWORD}@${REDIS_HOST}:${REDIS_PORT}"

echo "Release:   $RELEASE"
echo "Namespace: $NAMESPACE"
echo ""

# --- Select Gateway Implementation ---
echo "Select gateway implementation:"
echo "  1) Istio - service mesh with mTLS and authorization policies (recommended)"
echo "  2) Envoy Gateway - lightweight ingress-only routing"
echo ""
read -r -p "Choice [1]: " GATEWAY_CHOICE
GATEWAY_CHOICE="${GATEWAY_CHOICE:-1}"

case "$GATEWAY_CHOICE" in
  1)
    GATEWAY_CLASS="istio"
    ISTIO_ENABLED="true"
    ;;
  2)
    GATEWAY_CLASS="eg"
    ISTIO_ENABLED="false"
    ;;
  *)
    echo "Invalid choice. Exiting."
    exit 1
    ;;
esac

# --- Install bundled PostgreSQL and Redis? ---
read -r -p "Install bundled PostgreSQL? (y/n) [y]: " INSTALL_POSTGRES
INSTALL_POSTGRES="${INSTALL_POSTGRES:-y}"

read -r -p "Install bundled Redis? (y/n) [y]: " INSTALL_REDIS
INSTALL_REDIS="${INSTALL_REDIS:-y}"

# --- Install monitoring stack? ---
read -r -p "Install monitoring stack (Prometheus + Grafana)? (y/n) [n]: " INSTALL_MONITORING
INSTALL_MONITORING="${INSTALL_MONITORING:-n}"

MONITORING_ENABLED="false"
LOKI_ENABLED="false"
ALLOY_ENABLED="false"
if [ "$INSTALL_MONITORING" = "y" ]; then
  MONITORING_ENABLED="true"
  read -r -p "Also install log aggregation (Loki + Alloy)? (y/n) [n]: " INSTALL_LOGS
  INSTALL_LOGS="${INSTALL_LOGS:-n}"
  if [ "$INSTALL_LOGS" = "y" ]; then
    LOKI_ENABLED="true"
    ALLOY_ENABLED="true"
  fi
fi

if [ "$INSTALL_POSTGRES" != "y" ] && [ -z "$POSTGRES_HOST" ]; then
  read -r -p "PostgreSQL host: " POSTGRES_HOST
  read -r -p "PostgreSQL port [5432]: " POSTGRES_PORT
  POSTGRES_PORT="${POSTGRES_PORT:-5432}"
  read -r -p "PostgreSQL database [evtivity]: " POSTGRES_DB
  POSTGRES_DB="${POSTGRES_DB:-evtivity}"
  read -r -p "PostgreSQL user [evtivity]: " POSTGRES_USER
  POSTGRES_USER="${POSTGRES_USER:-evtivity}"
  read -r -s -p "PostgreSQL password: " POSTGRES_PASSWORD
  echo ""
  DATABASE_URL="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
fi

if [ "$INSTALL_REDIS" != "y" ] && [ -z "$REDIS_HOST" ]; then
  read -r -p "Redis host: " REDIS_HOST
  read -r -p "Redis port [6379]: " REDIS_PORT
  REDIS_PORT="${REDIS_PORT:-6379}"
  read -r -s -p "Redis password: " REDIS_PASSWORD
  echo ""
  REDIS_URL="redis://default:${REDIS_PASSWORD}@${REDIS_HOST}:${REDIS_PORT}"
fi

echo ""

if [ "$GATEWAY_CLASS" = "istio" ]; then
  # --- Install Istio ---
  if ! helm list -n istio-system 2>/dev/null | grep -q "istiod"; then
    echo "Installing Istio..."
    helm repo add istio https://istio-release.storage.googleapis.com/charts
    helm repo update istio

    helm install istio-base istio/base \
      --namespace istio-system \
      --create-namespace \
      --wait --timeout 5m \
      > /dev/null 2>&1

    helm install istiod istio/istiod \
      --namespace istio-system \
      --wait --timeout 5m \
      > /dev/null 2>&1

    echo "Istio ready."
  else
    echo "Istio already installed."
  fi
else
  # --- Install Envoy Gateway ---
  if ! helm list -A 2>/dev/null | grep -q "eg "; then
    echo "Installing Envoy Gateway..."
    helm install eg oci://docker.io/envoyproxy/gateway-helm \
      --version v1.3.2 \
      --namespace envoy-gateway-system \
      --create-namespace \
      --wait --timeout 5m \
      > /dev/null 2>&1
    echo "Envoy Gateway ready."
  else
    echo "Envoy Gateway already installed."
  fi
fi

# Ensure Gateway API CRDs are present
if ! kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
  echo "Installing Gateway API CRDs..."
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml > /dev/null 2>&1
  echo "Gateway API CRDs ready."
fi

# --- Install PostgreSQL ---
if [ "$INSTALL_POSTGRES" = "y" ]; then
  echo "Installing PostgreSQL..."
  helm repo add bitnami https://charts.bitnami.com/bitnami &>/dev/null || true
  helm upgrade --install "${RELEASE}-postgresql" bitnami/postgresql \
    --namespace "$NAMESPACE" \
    --create-namespace \
    --wait --timeout 5m \
    --set auth.username="$POSTGRES_USER" \
    --set auth.password="$POSTGRES_PASSWORD" \
    --set auth.database="$POSTGRES_DB" \
    --set "primary.initdb.scripts.grant-schema\\.sql=GRANT CREATE ON DATABASE $POSTGRES_DB TO $POSTGRES_USER;" \
    > /dev/null 2>&1
  echo "PostgreSQL ready."
else
  echo "Skipping bundled PostgreSQL (using $POSTGRES_HOST:$POSTGRES_PORT)."
fi

# --- Install Redis ---
if [ "$INSTALL_REDIS" = "y" ]; then
  echo "Installing Redis..."
  helm upgrade --install "${RELEASE}-redis" bitnami/redis \
    --namespace "$NAMESPACE" \
    --create-namespace \
    --wait --timeout 5m \
    --set auth.enabled=true \
    --set auth.password="$REDIS_PASSWORD" \
    --set replica.replicaCount=0 \
    > /dev/null 2>&1
  echo "Redis ready."
else
  echo "Skipping bundled Redis (using $REDIS_HOST:$REDIS_PORT)."
fi

# --- Generate OCPP mTLS and CSS Client Certificates ---
OCPP_TLS_SECRET="${RELEASE}-ocpp-tls"
CSS_TLS_SECRET="${RELEASE}-css-tls"
CERT_DIR=$(mktemp -d)
trap 'rm -rf "$CERT_DIR"' EXIT

echo "Generating OCPP mTLS certificates..."

# CA
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$CERT_DIR/ca-key.pem" -out "$CERT_DIR/ca.pem" \
  -days 3650 -nodes -subj "/CN=EVtivity OCPP CA" 2>/dev/null

# Server cert signed by CA
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$CERT_DIR/tls.key" -out "$CERT_DIR/server.csr" \
  -nodes -subj "/CN=EVtivity OCPP Server" 2>/dev/null
openssl x509 -req -in "$CERT_DIR/server.csr" \
  -CA "$CERT_DIR/ca.pem" -CAkey "$CERT_DIR/ca-key.pem" -CAcreateserial \
  -out "$CERT_DIR/tls.crt" -days 3650 2>/dev/null

# Client cert for CSS simulator signed by same CA
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$CERT_DIR/client-key.pem" -out "$CERT_DIR/client.csr" \
  -nodes -subj "/CN=css-simulator" 2>/dev/null
openssl x509 -req -in "$CERT_DIR/client.csr" \
  -CA "$CERT_DIR/ca.pem" -CAkey "$CERT_DIR/ca-key.pem" -CAcreateserial \
  -out "$CERT_DIR/client.pem" -days 3650 2>/dev/null

# Delete existing secrets if present, then create fresh
kubectl delete secret "$OCPP_TLS_SECRET" --namespace "$NAMESPACE" --ignore-not-found > /dev/null 2>&1
kubectl create secret generic "$OCPP_TLS_SECRET" \
  --namespace "$NAMESPACE" \
  --from-file=tls.crt="$CERT_DIR/tls.crt" \
  --from-file=tls.key="$CERT_DIR/tls.key" \
  --from-file=ca.crt="$CERT_DIR/ca.pem" \
  > /dev/null 2>&1

kubectl delete secret "$CSS_TLS_SECRET" --namespace "$NAMESPACE" --ignore-not-found > /dev/null 2>&1
kubectl create secret generic "$CSS_TLS_SECRET" \
  --namespace "$NAMESPACE" \
  --from-file=client.pem="$CERT_DIR/client.pem" \
  --from-file=client-key.pem="$CERT_DIR/client-key.pem" \
  --from-file=ca.pem="$CERT_DIR/ca.pem" \
  > /dev/null 2>&1

echo "OCPP mTLS and CSS client certificates ready."

# --- Install EVtivity CSMS ---
echo "Installing EVtivity CSMS..."
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --set fullnameOverride="$RELEASE" \
  --set 'image.pullSecrets[0].name=ghcr-secret' \
  --set gatewayAPI.gateway.gatewayClassName="$GATEWAY_CLASS" \
  --set istio.enabled="$ISTIO_ENABLED" \
  --set dependencies.postgresHost="$POSTGRES_HOST" \
  --set dependencies.postgresPort="$POSTGRES_PORT" \
  --set dependencies.redisHost="$REDIS_HOST" \
  --set dependencies.redisPort="$REDIS_PORT" \
  --set secrets.databaseUrl="$DATABASE_URL" \
  --set secrets.redisUrl="$REDIS_URL" \
  --set secrets.jwtSecret="$JWT_SECRET" \
  --set secrets.settingsEncryptionKey="$SETTINGS_ENCRYPTION_KEY" \
  --set ocpp.tls.enabled=true \
  --set ocpp.tls.certSecret="$OCPP_TLS_SECRET" \
  --set css.tls.enabled=true \
  --set css.tls.certSecret="$CSS_TLS_SECRET" \
  --set monitoring.enabled="$MONITORING_ENABLED" \
  --set monitoring.loki.enabled="$LOKI_ENABLED" \
  --set monitoring.alloy.enabled="$ALLOY_ENABLED" \
  --set ocpi.enabled=true \
  --set ocpiSim.enabled=true \
  --set ocpiCpoSim.enabled=true \
  --set initialAdmin.password="$ADMIN_PASSWORD" \
  --set api.env.cookieDomain=".evtivity.local"
echo "EVtivity CSMS ready."
echo "Admin email: admin@evtivity.local"
echo "Admin password: $ADMIN_PASSWORD (must be changed on first login)"

echo ""
echo "Run 'kubectl get pods -n $NAMESPACE' to check status."
