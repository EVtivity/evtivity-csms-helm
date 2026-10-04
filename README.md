<p align="center">
  <img src="assets/evtivity-logo.svg" alt="EVtivity" width="80" height="80" />
</p>

<h1 align="center">EVtivity CSMS Helm Chart</h1>

<p align="center">
  <a href="https://github.com/EVtivity/evtivity-csms-helm/releases/latest"><img src="https://img.shields.io/github/v/release/EVtivity/evtivity-csms-helm?label=Release&color=4ade80" alt="Release" /></a>
  <a href="https://github.com/EVtivity/evtivity-csms/blob/main/LICENSE.md"><img src="https://img.shields.io/badge/License-BUSL--1.1-blue.svg" alt="License: BUSL-1.1" /></a>
  <img src="https://img.shields.io/badge/Helm-3.12%2B-0F1689.svg" alt="Helm" />
  <img src="https://img.shields.io/badge/Kubernetes-1.26%2B-326CE5.svg" alt="Kubernetes" />
</p>

Helm chart for deploying [EVtivity CSMS](https://github.com/EVtivity/evtivity-csms) on Kubernetes.

## Prerequisites

- Kubernetes 1.26+
- Helm 3.12+

## Quick Start (minikube)

```bash
minikube start --cpus=4 --memory=12288
./scripts/install.sh
```

12GB is the minimum with all services enabled (monitoring, simulators). Set Docker Desktop memory to at least 14GB (Settings > Resources) to allow headroom for rolling updates. With monitoring and simulators disabled, 8GB is sufficient.

The script installs all dependencies (Istio or Envoy Gateway, PostgreSQL, Redis), generates TLS certificates, and deploys the CSMS.

After install, start the tunnel in a separate terminal (keeps running):

```bash
minikube tunnel
```

Then add hostnames to `/etc/hosts` using the tunnel IP (usually `127.0.0.1`):

```bash
echo "127.0.0.1 csms.evtivity.local portal.evtivity.local api.evtivity.local ocpp.evtivity.local" | sudo tee -a /etc/hosts
```

Check pod status:

```bash
kubectl get pods -n evtivity
```

The install script prints the admin email and password on completion. Save the password - you must change it on first login.

Access the dashboard at `http://csms.evtivity.local`.

## Install

```bash
./scripts/install.sh
```

The script prompts for gateway implementation (Istio or Envoy Gateway), installs PostgreSQL, Redis, generates OCPP TLS certificates, and deploys the CSMS chart with random secrets.

To provide your own secrets:

```bash
POSTGRES_PASSWORD=mypass REDIS_PASSWORD=mypass JWT_SECRET=mysecret SETTINGS_ENCRYPTION_KEY=mykey ./scripts/install.sh
```

To use external databases instead of bundled ones:

```bash
POSTGRES_HOST=db.example.com REDIS_HOST=redis.example.com ./scripts/install.sh
```

## Uninstall

```bash
./scripts/uninstall.sh
```

Removes all Helm releases and prompts to delete PVCs and the namespace.

## Upgrading

To upgrade to a new version:

```bash
helm upgrade evtivity . --namespace evtivity --reuse-values --set image.tag=0.2.0
```

Database migrations run in a `pre-upgrade` hook job (`post-install` on a fresh install). On upgrade Helm runs the job before it updates the Deployments, so new pods never start against the old schema, and a failed migration stops the upgrade with the old pods still running. The job reads `DATABASE_URL` from the Secret of the installed release. To change the database URL, upgrade with the new `secrets.databaseUrl` first, then upgrade the image. The settings seed job (`post-upgrade`) runs after the migration and the new app settings.

**Upgrading to per-service Redis users (0.1.38).** `secrets.redisUrl` and the Secret key `REDIS_URL` were replaced by one URL per service (see [Redis Access Control](#redis-access-control)). The chart refuses to render while `secrets.redisUrl` is set or a URL of an enabled service is missing.

1. Create the five users in Redis. Keep the credential the running pods use. With the bundled Redis, re-running `scripts/install.sh` does this step and the next one.
2. Upgrade with `--set secrets.redisUrl=` and the five `secrets.redisUrls.*` values, or add the five `REDIS_URL_*` keys to your existing Secret. Pods switch users as they roll. A pod that starts without its key fails with `CreateContainerConfigError` while the old pods keep running.
3. When every pod runs the new version, disable or rotate the old credential.

To reload the same version (pulls fresh images):

```bash
helm upgrade evtivity . --namespace evtivity --reuse-values --set image.pullPolicy=Always
```

To restart all pods without changing Helm values:

```bash
kubectl rollout restart deployment -n evtivity
```

## Services

| Service | Default Port | Description |
|---------|-------------|-------------|
| API | 3001 | REST API (Fastify) |
| OCPP | 8080 (ws), 8443 (wss) | OCPP 1.6/2.1 WebSocket server |
| OCPI | 3002 | OCPI 2.2.1/2.3.0 roaming server |
| CSMS | 80 | Operator dashboard (React + Nginx) |
| Portal | 80 | Driver portal (React + Nginx) |
| Worker | - | Background job processor (BullMQ) |
| CSS | - | Charging station simulator (internal) |

Each service can be toggled with `{service}.enabled` and configured with `replicaCount`, `resources`, `nodeSelector`, `tolerations`, and `affinity`. API and OCPP support HPA autoscaling.

## Configuration

All configuration is in `values.yaml`. Override with `--set` flags or a custom values file.

### Secrets

| Parameter | Description |
|-----------|-------------|
| `secrets.databaseUrl` | PostgreSQL connection string |
| `secrets.redisUrls.api` | Redis URL of the `api` ACL user |
| `secrets.redisUrls.ocpp` | Redis URL of the `ocpp` ACL user |
| `secrets.redisUrls.ocpi` | Redis URL of the `ocpi` ACL user (required when `ocpi.enabled`) |
| `secrets.redisUrls.worker` | Redis URL of the `worker` ACL user |
| `secrets.redisUrls.css` | Redis URL of the `css` ACL user (required when `css.enabled`) |
| `secrets.jwtSecret` | JWT signing secret |
| `secrets.settingsEncryptionKey` | AES-256 encryption key for settings |

For GitOps or Vault workflows, set `secrets.create: false` and `secrets.existingSecret: my-secret-name`. The Secret must contain: `DATABASE_URL`, `REDIS_URL_API`, `REDIS_URL_OCPP`, `REDIS_URL_OCPI`, `REDIS_URL_WORKER`, `REDIS_URL_CSS`, `JWT_SECRET`, `SETTINGS_ENCRYPTION_KEY`.

### Redis Access Control

Each service connects to Redis as its own ACL user. `redis/acl-rules.conf` lists the users and what each may do:

| User | Keys | Channels |
|------|------|----------|
| `api` | response cache (`rc:*`), attestation nonces, the payment process watch key (read only) | core channels, simulator channels |
| `ocpp` | station connection registry (`ocpp:conn:*`) | core channels |
| `worker` | BullMQ queues (`bull:*`), maintenance locks, the payment process watch key | core channels |
| `ocpi` | OCPI pull locks (`opl:*`) | `ocpp_commands`, `ocpp_command_results`, `csms_events`, `ocpi_*` |
| `css` | none | `css_commands`, `css_command_results` |

Every user may run all commands except the `@dangerous` category (`CONFIG`, `MODULE`, `FLUSHALL`, `KEYS`, `REPLICAOF`, `SHUTDOWN`, `ACL SETUSER` and others), plus `INFO`, which BullMQ needs. A leaked simulator or OCPI credential can no longer command stations, read queued jobs, or reconfigure Redis. No service uses the Redis `default` user.

**Bundled Redis.** `scripts/install.sh` creates the five users in the Bitnami Redis release (`auth.acl.users`), with generated passwords unless `REDIS_API_PASSWORD`, `REDIS_OCPP_PASSWORD`, `REDIS_OCPI_PASSWORD`, `REDIS_WORKER_PASSWORD` or `REDIS_CSS_PASSWORD` is set, and passes each service its URL. `REDIS_PASSWORD` stays the password of the Redis `default` (admin) user.

**External Redis.** Create the users before you install or upgrade the chart. Redis 7 or later is required for the `%R~` read-only key rule. This prints one `ACL SETUSER` command per user. Replace each `CHANGE_ME_*` with a password (URL-safe, no commas):

```bash
awk '$1 == "user" { name = $2; $1 = $2 = ""; printf "ACL SETUSER %s reset on >CHANGE_ME_%s%s\n", name, toupper(name), $0 }' redis/acl-rules.conf
```

Run the commands with `redis-cli` as an admin user, then persist them (`ACL SAVE` with an ACL file, or `CONFIG REWRITE`). Set `secrets.redisUrls.<user>` to `redis://<user>:<password>@<host>:<port>` (or `rediss://` for TLS). To install against a Redis without ACL support, set all five URLs to the same URL.

### Redis TLS

Off by default. With TLS on, the per-service passwords and all Redis traffic are encrypted between the pods and Redis, which sits outside the Istio mesh.

**Bundled Redis.** Run `REDIS_TLS=true ./scripts/install.sh` (or answer yes to the TLS prompt). The script stores the Redis server certificate in the Secret `<release>-redis-tls` (`tls.crt`, `tls.key`, `ca.crt`), starts Bitnami Redis with TLS only on port 6379 (`tls.enabled`, no client certificates), switches the service URLs to `rediss://`, and sets `redisTls.enabled` and `redisTls.caSecret`. The certificate covers `<release>-redis-master` (short, namespace, and cluster names), the headless pod names, and `localhost`.

- Self-signed (default): the script makes a private CA and the server certificate (P-256, 10 years).
- cert-manager: set `REDIS_TLS_ISSUER` (and `REDIS_TLS_ISSUER_KIND`, default `ClusterIssuer`). The script creates a `Certificate` and waits for it. Use a CA or self-signed issuer, so the Secret carries `ca.crt`.

An existing `<release>-redis-tls` Secret is kept on a re-run, so the running Redis and the services keep the same CA.

**Chart values.** `redisTls.enabled: true` with `redisTls.caSecret` (and `redisTls.caKey`, default `ca.crt`) gives every service `REDIS_TLS_CA_PEM` from that Secret, and the services verify the Redis certificate against it. The chart refuses to render while a URL of an enabled service is not `rediss://`. A Redis with a certificate from a public CA (a managed Redis) needs only `rediss://` URLs, not `redisTls`.

**External Redis with a private CA.** Run the install script with `REDIS_TLS=true REDIS_TLS_CA_SECRET=<secret with ca.crt>`, or set the values above yourself.

### Payment Settings

Payment settings are app settings in the database, and credentials are stored encrypted. Pass credentials with `--set` or an existing Secret (`appSettings.sensitive.existingSecret`). An empty value keeps the one set in Settings > Payment.

| Parameter | Setting |
|-----------|---------|
| `appSettings.payments.provider` | Provider of new payments: `none`, `stripe`, or `simulated`. Adyen is selected in Settings > Payment after the upgrade; the chart refuses `adyen` |
| `appSettings.payments.preAuthAmountCents` | Default pre-authorization amount in cents, 1 to 1000000 (5000 on a fresh install) |
| `appSettings.payments.platformFeePercent` | Default platform fee percentage, 0 to 100 (0 on a fresh install) |
| `appSettings.simulated.resultMode` | Test provider result mode: `sync` (results in the API response) or `async` (results confirmed later through the payment webhook pipeline after `asyncDelaySeconds`) |
| `appSettings.simulated.asyncDelaySeconds` | Test provider delay of async results in seconds, 0 to 3600 |
| `appSettings.simulated.randomFailureRate` | Test provider failure rate of cards without a scenario, 0 to 1 |
| `appSettings.sensitive.stripeSecretKey` | Stripe secret or restricted key |
| `appSettings.sensitive.stripePublishableKey` | Stripe publishable key |
| `appSettings.sensitive.stripeWebhookSecret` | Signing secret of the Stripe platform webhook endpoint |
| `appSettings.sensitive.stripeConnectWebhookSecret` | Signing secret of the Stripe Connect webhook endpoint |
| `appSettings.sensitive.adyenApiKey` | Adyen API key |
| `appSettings.sensitive.adyenHmacKey` | Adyen webhook HMAC key (hex) |
| `appSettings.sensitive.adyenHmacKeyPrevious` | Previous Adyen HMAC key, accepted during a rotation |
| `appSettings.sensitive.adyenWebhookPassword` | Adyen webhook Basic auth password |

`appSettings.stripe.preAuthAmountCents` and `appSettings.stripe.platformFeePercent` moved to `appSettings.payments.*`, because they apply to every provider. The chart refuses the old names, also when `--reuse-values` carries them over from an earlier release. The upgrade copies the stored values to the new settings.

Both Stripe endpoints send to `https://<api host>/v1/webhooks/payments/stripe`, Adyen to `https://<api host>/v1/webhooks/payments/adyen`. Settings > Payment can create the webhooks and store these values for you.

### Initial Admin User

Created on first install via a `post-install` Helm hook. The user has `mustResetPassword: true` and must set a new password on first login.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `initialAdmin.enabled` | `true` | Create admin user on install |
| `initialAdmin.email` | `admin@evtivity.local` | Admin email |
| `initialAdmin.password` | `admin123` | Initial password (must be changed) |

### Gateway API

Each service gets its own hostname via HTTPRoute.

| Host | Service |
|------|---------|
| `csms.evtivity.dev` | Operator dashboard |
| `portal.evtivity.dev` | Driver portal |
| `api.evtivity.dev` | REST API |
| `ocpp.evtivity.dev` | OCPP WebSocket |
| `ocpi.evtivity.dev` | OCPI server |

The install script prompts for gateway implementation:

- **Istio** (default): Service mesh with inter-service mTLS and AuthorizationPolicy
- **Envoy Gateway**: Lightweight ingress-only routing

To use an existing Gateway:

```yaml
gatewayAPI:
  gateway:
    create: false
  parentRefs:
    - name: my-gateway
      namespace: gateway-infra
```

### OCPP TLS

Enabled by default. Creates a LoadBalancer service on port 8443 for direct station connections with TLS. Supports SP3 mTLS (client certificate authentication) alongside SP0-SP2 stations on the same port.

The install script generates self-signed certificates automatically. To use your own:

```yaml
ocpp:
  tls:
    enabled: true
    certSecret: my-ocpp-tls-secret
```

The Secret must contain `tls.crt`, `tls.key`, and `ca.crt`.

### Istio Policies

When Istio is selected:

- **PeerAuthentication**: Enforces mTLS between all pods
- **AuthorizationPolicy**: Each service only accepts traffic from the Istio gateway

OCPP TLS port (8443) is excluded from the sidecar so stations connect with their own TLS.

```yaml
istio:
  enabled: true
  peerAuthentication:
    mode: STRICT
```

### Monitoring

Disabled by default. When enabled, deploys Prometheus, Grafana, Loki, and Alloy with persistent storage.

```yaml
monitoring:
  enabled: true
  loki:
    enabled: true
  alloy:
    enabled: true
```

Grafana provisions Prometheus and Loki datasources with pre-built dashboards (system metrics, business metrics, logs).

### Rate Limiting

```yaml
api:
  env:
    rateLimitMax: 1000
    rateLimitWindow: "1 minute"
```

## License

Copyright (c) 2025-2026 EVtivity. All rights reserved. See [LICENSE.md](LICENSE.md) for full terms.
