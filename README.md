<p align="center">
  <img src="assets/evtivity-logo.svg" alt="EVtivity" width="80" height="80" />
</p>

<h1 align="center">EVtivity CSMS Helm Chart</h1>

<p align="center">
  <a href="https://github.com/EVtivity/evtivity-csms/blob/main/LICENSE.md"><img src="https://img.shields.io/badge/License-BUSL--1.1-blue.svg" alt="License: BUSL-1.1" /></a>
  <img src="https://img.shields.io/badge/Helm-3.12%2B-0F1689.svg" alt="Helm" />
  <img src="https://img.shields.io/badge/Kubernetes-1.26%2B-326CE5.svg" alt="Kubernetes" />
</p>

Helm chart for deploying EVtivity CSMS on Kubernetes.

## Prerequisites

- Kubernetes 1.26+
- Helm 3.12+

For local development with minikube, see the [Minikube Setup Guide](docs/minikube-setup.md).

## Install

```bash
./scripts/install.sh
```

The script installs PostgreSQL, Redis, and the CSMS chart. It generates random secrets and prompts you to save them before proceeding.

To provide your own secrets:

```bash
POSTGRES_PASSWORD=mypass REDIS_PASSWORD=mypass JWT_SECRET=mysecret SETTINGS_ENCRYPTION_KEY=mykey ./scripts/install.sh
```

## Uninstall

```bash
./scripts/uninstall.sh
```

The script removes all releases and prompts to delete data and the namespace.

## Configuration

All configuration is in `values.yaml`. Override values with `--set` flags or a custom values file.

### Secrets

| Parameter | Description |
|-----------|-------------|
| `secrets.databaseUrl` | PostgreSQL connection string |
| `secrets.redisUrl` | Redis connection string |
| `secrets.jwtSecret` | JWT signing secret |
| `secrets.settingsEncryptionKey` | Settings encryption key |

For GitOps or Vault workflows, set `secrets.create: false` and `secrets.existingSecret: my-secret-name`. The Secret must contain: `DATABASE_URL`, `REDIS_URL`, `JWT_SECRET`, `SETTINGS_ENCRYPTION_KEY`.

### Initial Admin User

The chart creates an admin user on first install via a `post-install` Helm hook. The user is created with `mustResetPassword: true`. On first login, the CSMS redirects to a password change form where the admin sets a new password.


### Gateway API

Enabled by default. The install script prompts you to choose a gateway implementation:

- **Istio** (default) - Service mesh with inter-service mTLS and AuthorizationPolicy. Each service only accepts traffic from the Istio gateway.
- **Envoy Gateway** - Lightweight ingress-only routing. No mesh policies.

Each service gets its own hostname and HTTPRoute.

Default routes:

| Host | Service |
|------|---------|
| `csms.evtivity.dev` | CSMS frontend |
| `portal.evtivity.dev` | Portal frontend |
| `api.evtivity.dev` | REST API |
| `ocpp.evtivity.dev` | OCPP WebSocket |
| `ocpi.evtivity.dev` | OCPI roaming |

To use an existing Gateway instead of creating one:

```yaml
gatewayAPI:
  gateway:
    create: false
  parentRefs:
    - name: my-gateway
      namespace: gateway-infra
```

### Istio Policies

When Istio is selected, the chart creates:

- **PeerAuthentication**: Enforces mTLS between all pods in the namespace
- **AuthorizationPolicy**: Each service only accepts traffic from the Istio gateway

OCPP TLS port (8443) is excluded from the Istio sidecar so stations connect directly with their own TLS.

No policies are created for PostgreSQL or Redis. Manage those independently.

To customize:

```yaml
istio:
  enabled: true
  peerAuthentication:
    mode: STRICT
```

### Services

Each service (api, ocpp, ocpi, csms, portal) supports `enabled`, `replicaCount`, `resources`, `nodeSelector`, `tolerations`, and `affinity`. API and OCPP also support `autoscaling`.

## License

Copyright (c) 2025-2026 EVtivity. All rights reserved. See [LICENSE.md](LICENSE.md) for full terms.
