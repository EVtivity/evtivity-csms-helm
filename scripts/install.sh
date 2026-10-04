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

# Each service connects to Redis as its own ACL user. Users, keys, channels and
# commands are in redis/acl-rules.conf. REDIS_PASSWORD stays the password of the
# Redis default (admin) user, which no service uses.
REDIS_ACL_RULES="$CHART_DIR/redis/acl-rules.conf"
REDIS_ACL_USERS="api ocpp ocpi worker css"

# Temporary files (certificates, Redis ACL values with passwords), removed on exit.
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

redis_password_of() {
  local var
  var="REDIS_$(echo "$1" | tr '[:lower:]' '[:upper:]')_PASSWORD"
  printf '%s' "${!var}"
}

redis_url_of() {
  local scheme=redis
  [ "$REDIS_TLS" = "true" ] && scheme=rediss
  printf '%s://%s:%s@%s:%s' "$scheme" "$1" "$(redis_password_of "$1")" "$REDIS_HOST" "$REDIS_PORT"
}

# Prints Bitnami Redis values that create one ACL user per line of the rules
# file. Bitnami needs keys, channels and commands as separate fields, and
# defaults an empty keys field to "~*", so a user without keys gets "resetkeys".
redis_acl_values() {
  local keyword name rest tok keys channels commands
  printf 'auth:\n  acl:\n    enabled: true\n    users:\n'
  while read -r keyword name rest; do
    [ "$keyword" = "user" ] || continue
    keys=""
    channels=""
    commands=""
    set -f
    for tok in $rest; do
      case "$tok" in
        "~"* | "%"*) keys="$keys $tok" ;;
        "&"*) channels="$channels $tok" ;;
        *) commands="$commands $tok" ;;
      esac
    done
    set +f
    [ -n "$keys" ] || keys=" resetkeys"
    printf '      - username: "%s"\n' "$name"
    printf '        password: "%s"\n' "$(redis_password_of "$name")"
    printf '        enabled: "on"\n'
    printf '        keys: "%s"\n' "${keys# }"
    printf '        channels: "%s"\n' "${channels# }"
    printf '        commands: "%s"\n' "${commands# }"
  done < "$REDIS_ACL_RULES"
}

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

# --- Redis TLS (opt in) ---
# REDIS_TLS=true serves the bundled Redis over TLS. Its certificate comes from
# cert-manager when REDIS_TLS_ISSUER names an issuer (REDIS_TLS_ISSUER_KIND,
# default ClusterIssuer; it must fill ca.crt, as CA and self-signed issuers do),
# else from a self-signed CA made here. Both land in the Secret
# <release>-redis-tls. For an external Redis, REDIS_TLS=true switches the URLs to
# rediss://; set REDIS_TLS_CA_SECRET to a Secret with its CA in ca.crt when the
# certificate is not from a public CA.
if [ -z "${REDIS_TLS:-}" ] && [ "$INSTALL_REDIS" = "y" ]; then
  read -r -p "Serve the bundled Redis over TLS? (y/n) [n]: " REDIS_TLS_ANSWER
  [ "${REDIS_TLS_ANSWER:-n}" = "y" ] && REDIS_TLS=true
fi
REDIS_TLS="${REDIS_TLS:-false}"
REDIS_TLS_SECRET="${RELEASE}-redis-tls"
REDIS_TLS_CA_SECRET="${REDIS_TLS_CA_SECRET:-}"
if [ "$REDIS_TLS" = "true" ] && [ "$INSTALL_REDIS" = "y" ]; then
  REDIS_TLS_CA_SECRET="$REDIS_TLS_SECRET"
fi

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
fi

# --- Names for the OCPP TLS server certificate ---
# Stations that verify the hostname reject a certificate without a matching
# subjectAltName. Checked here, before anything is installed.
# OCPP_TLS_HOSTS: comma-separated DNS names. Default: the OCPP gateway route
#   host(s) in values.yaml.
# OCPP_TLS_IPS: comma-separated IP addresses (e.g. the TLS LoadBalancer IP).
# The in-cluster OCPP Service names (used by the simulator) are always added.
if [ -z "${OCPP_TLS_HOSTS:-}" ]; then
  OCPP_TLS_HOSTS="$(awk '
    /^[^[:space:]#]/ { in_gw = ($0 ~ /^gatewayAPI:/) }
    in_gw && /^[[:space:]]*- host:/ { host = $3 }
    in_gw && /^[[:space:]]*service:[[:space:]]*ocpp[[:space:]]*$/ && host != "" { print host }
  ' "$CHART_DIR/values.yaml" | tr -d "\"'" | sort -u | paste -sd, -)"
fi
OCPP_TLS_IPS="${OCPP_TLS_IPS:-}"

OCPP_SAN=""
add_san() {
  if [ -n "$OCPP_SAN" ]; then OCPP_SAN="${OCPP_SAN},"; fi
  OCPP_SAN="${OCPP_SAN}$1"
}
OCPP_SERVICE="${RELEASE}-ocpp"
for name in $(echo "$OCPP_TLS_HOSTS" | tr ',' ' ') "$OCPP_SERVICE" "${OCPP_SERVICE}.${NAMESPACE}" \
  "${OCPP_SERVICE}.${NAMESPACE}.svc" "${OCPP_SERVICE}.${NAMESPACE}.svc.cluster.local"; do
  if ! echo "$name" | grep -Eq '^(\*\.)?[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'; then
    echo "Invalid OCPP TLS host name: $name"
    exit 1
  fi
  add_san "DNS:$name"
done
for ip in $(echo "$OCPP_TLS_IPS" | tr ',' ' '); do
  if ! echo "$ip" | grep -Eq '^([0-9]{1,3}(\.[0-9]{1,3}){3}|[0-9A-Fa-f:]*:[0-9A-Fa-f:.]*)$'; then
    echo "Invalid OCPP TLS IP address: $ip"
    exit 1
  fi
  add_san "IP:$ip"
done
echo "OCPP TLS certificate names: $OCPP_SAN"

# --- Redis ACL users: one per service (redis/acl-rules.conf) ---
# Bundled Redis: passwords are generated unless REDIS_<USER>_PASSWORD is set.
# External Redis: create the users first (README, "External Redis") and enter
# their passwords, or set REDIS_<USER>_PASSWORD.
for user in $REDIS_ACL_USERS; do
  var="REDIS_$(echo "$user" | tr '[:lower:]' '[:upper:]')_PASSWORD"
  if [ -z "${!var:-}" ]; then
    if [ "$INSTALL_REDIS" = "y" ]; then
      printf -v "$var" '%s' "$(generate_secret)"
    else
      read -r -s -p "Password of Redis user '$user': " "$var"
      echo ""
    fi
  fi
done

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

# --- Redis TLS certificate (bundled Redis, REDIS_TLS=true) ---
REDIS_TLS_ARGS=()
if [ "$REDIS_TLS" = "true" ] && [ "$INSTALL_REDIS" = "y" ]; then
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - > /dev/null
  REDIS_TLS_DNS=(
    "${RELEASE}-redis-master"
    "${RELEASE}-redis-master.${NAMESPACE}"
    "${RELEASE}-redis-master.${NAMESPACE}.svc"
    "${RELEASE}-redis-master.${NAMESPACE}.svc.cluster.local"
    "*.${RELEASE}-redis-headless.${NAMESPACE}.svc.cluster.local"
    "localhost"
  )
  if kubectl get secret "$REDIS_TLS_SECRET" --namespace "$NAMESPACE" > /dev/null 2>&1; then
    # Keep the certificate the running Redis serves; a new CA would need a
    # Redis restart before the services trust it.
    echo "Redis TLS certificate exists ($REDIS_TLS_SECRET), keeping it."
  elif [ -n "${REDIS_TLS_ISSUER:-}" ]; then
    echo "Requesting the Redis TLS certificate from cert-manager ($REDIS_TLS_ISSUER)..."
    {
      echo "apiVersion: cert-manager.io/v1"
      echo "kind: Certificate"
      echo "metadata:"
      echo "  name: ${REDIS_TLS_SECRET}"
      echo "  namespace: ${NAMESPACE}"
      echo "spec:"
      echo "  secretName: ${REDIS_TLS_SECRET}"
      echo "  commonName: ${RELEASE}-redis-master"
      echo "  dnsNames:"
      for name in "${REDIS_TLS_DNS[@]}"; do echo "    - \"${name}\""; done
      echo "  ipAddresses:"
      echo "    - 127.0.0.1"
      echo "  issuerRef:"
      echo "    name: ${REDIS_TLS_ISSUER}"
      echo "    kind: ${REDIS_TLS_ISSUER_KIND:-ClusterIssuer}"
    } | kubectl apply -f - > /dev/null
    kubectl wait --for=condition=Ready "certificate/${REDIS_TLS_SECRET}" \
      --namespace "$NAMESPACE" --timeout=3m > /dev/null
    if [ -z "$(kubectl get secret "$REDIS_TLS_SECRET" --namespace "$NAMESPACE" -o jsonpath='{.data.ca\.crt}')" ]; then
      echo "Error: ${REDIS_TLS_SECRET} has no ca.crt. Use a CA or self-signed issuer."
      exit 1
    fi
  else
    echo "Generating the Redis TLS certificate..."
    REDIS_CERT_DIR="$WORK_DIR/redis-tls"
    mkdir -p "$REDIS_CERT_DIR"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$REDIS_CERT_DIR/ca.key" -out "$REDIS_CERT_DIR/ca.crt" \
      -days 3650 -nodes -subj "/CN=EVtivity Redis CA" 2>/dev/null
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$REDIS_CERT_DIR/tls.key" -out "$REDIS_CERT_DIR/tls.csr" \
      -nodes -subj "/CN=${RELEASE}-redis-master" 2>/dev/null
    {
      printf 'subjectAltName='
      for name in "${REDIS_TLS_DNS[@]}"; do printf 'DNS:%s,' "$name"; done
      printf 'IP:127.0.0.1\n'
      printf 'extendedKeyUsage=serverAuth\n'
    } > "$REDIS_CERT_DIR/san.ext"
    openssl x509 -req -in "$REDIS_CERT_DIR/tls.csr" \
      -CA "$REDIS_CERT_DIR/ca.crt" -CAkey "$REDIS_CERT_DIR/ca.key" -CAcreateserial \
      -extfile "$REDIS_CERT_DIR/san.ext" \
      -out "$REDIS_CERT_DIR/tls.crt" -days 3650 2>/dev/null
    kubectl create secret generic "$REDIS_TLS_SECRET" \
      --namespace "$NAMESPACE" \
      --from-file=tls.crt="$REDIS_CERT_DIR/tls.crt" \
      --from-file=tls.key="$REDIS_CERT_DIR/tls.key" \
      --from-file=ca.crt="$REDIS_CERT_DIR/ca.crt" \
      > /dev/null
  fi
  # Clients authenticate with their ACL password, not a client certificate.
  REDIS_TLS_ARGS=(
    --set tls.enabled=true
    --set tls.authClients=false
    --set tls.existingSecret="$REDIS_TLS_SECRET"
    --set tls.certFilename=tls.crt
    --set tls.certKeyFilename=tls.key
    --set tls.certCAFilename=ca.crt
  )
fi

# --- Install Redis ---
if [ "$INSTALL_REDIS" = "y" ]; then
  echo "Installing Redis..."
  # Passwords go into a values file, not auth.acl.userSecret: Bitnami reads that
  # Secret with lookup, which renders the users without a password under
  # helm template or Argo CD.
  (umask 077 && redis_acl_values > "$WORK_DIR/redis-acl.yaml")
  helm upgrade --install "${RELEASE}-redis" bitnami/redis \
    --namespace "$NAMESPACE" \
    --create-namespace \
    --wait --timeout 5m \
    --set auth.enabled=true \
    --set auth.password="$REDIS_PASSWORD" \
    --set replica.replicaCount=0 \
    -f "$WORK_DIR/redis-acl.yaml" \
    ${REDIS_TLS_ARGS[@]+"${REDIS_TLS_ARGS[@]}"} \
    > /dev/null 2>&1
  echo "Redis ready."
else
  echo "Skipping bundled Redis (using $REDIS_HOST:$REDIS_PORT)."
fi

# --- Generate OCPP mTLS and CSS Client Certificates ---
OCPP_TLS_SECRET="${RELEASE}-ocpp-tls"
CSS_TLS_SECRET="${RELEASE}-css-tls"
CERT_DIR="$WORK_DIR/certs"
mkdir -p "$CERT_DIR"

echo "Generating OCPP mTLS certificates..."

# CA
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$CERT_DIR/ca-key.pem" -out "$CERT_DIR/ca.pem" \
  -days 3650 -nodes -subj "/CN=EVtivity OCPP CA" 2>/dev/null

# Server cert signed by CA. The extensions file sets the subjectAltName
# (x509 -req does not copy CSR extensions on every OpenSSL or LibreSSL).
cat > "$CERT_DIR/server-ext.cnf" <<EOF
basicConstraints=CA:FALSE
extendedKeyUsage=serverAuth
subjectAltName=$OCPP_SAN
EOF
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$CERT_DIR/tls.key" -out "$CERT_DIR/server.csr" \
  -nodes -subj "/CN=EVtivity OCPP Server" 2>/dev/null
openssl x509 -req -in "$CERT_DIR/server.csr" \
  -CA "$CERT_DIR/ca.pem" -CAkey "$CERT_DIR/ca-key.pem" -CAcreateserial \
  -extfile "$CERT_DIR/server-ext.cnf" \
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
  --set secrets.redisUrls.api="$(redis_url_of api)" \
  --set secrets.redisUrls.ocpp="$(redis_url_of ocpp)" \
  --set secrets.redisUrls.ocpi="$(redis_url_of ocpi)" \
  --set secrets.redisUrls.worker="$(redis_url_of worker)" \
  --set secrets.redisUrls.css="$(redis_url_of css)" \
  --set redisTls.enabled="$([ -n "$REDIS_TLS_CA_SECRET" ] && echo true || echo false)" \
  --set redisTls.caSecret="$REDIS_TLS_CA_SECRET" \
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
