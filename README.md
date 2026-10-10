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

The bundled PostgreSQL and Redis use pinned Bitnami chart versions that were tested with this chart. `POSTGRES_CHART_VERSION` and `REDIS_CHART_VERSION` override them. Redis chart 27 and later do not start with the per-service ACL users.

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

Each service can be toggled with `{service}.enabled` and configured with `replicaCount`, `resources`, `nodeSelector`, `tolerations`, and `affinity`. API, OCPP, and the worker support HPA autoscaling (`{service}.autoscaling.enabled`, `minReplicas`, `maxReplicas`, `targetCPUUtilization`). The worker scales on CPU from 1 to 4 replicas when enabled. Keep it at one replica when `worker.env.octtOcspResponderUrl` is set: the chart refuses more.

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

With [Credential Rotation](#credential-rotation) on, the database and Redis URLs move to the job-owned Secret `<fullname>-credentials` once, and the services read them from there.

### Redis Access Control

Each service connects to Redis as its own ACL user. `redis/acl-rules.conf` lists the users and what each may do:

| User | Keys | Channels |
|------|------|----------|
| `api` | response cache (`rc:*`), attestation nonces, the payment process watch key (read only) | core channels, simulator channels |
| `ocpp` | station connection registry (`ocpp:conn:*`) | core channels |
| `worker` | BullMQ queues (`bull:*`), maintenance (`mfl:*`), station message (`sml:*`) and job (`wkl:*`) locks, the payment process watch key, the station connection registry (read only) | core channels |
| `ocpi` | OCPI pull locks (`opl:*`) | `ocpp_commands`, `ocpp_command_results`, `csms_events`, `ocpi_*` |
| `css` | none | `css_commands`, `css_command_results` |

Every user may run all commands except the `@dangerous` category (`CONFIG`, `MODULE`, `FLUSHALL`, `KEYS`, `REPLICAOF`, `SHUTDOWN`, `ACL SETUSER` and others), plus `INFO`, which BullMQ needs. A leaked simulator or OCPI credential can no longer command stations, read queued jobs, or reconfigure Redis. No service uses the Redis `default` user.

**Bundled Redis.** `scripts/install.sh` creates the five users in the Bitnami Redis release (`auth.acl.users`), with generated passwords unless `REDIS_API_PASSWORD`, `REDIS_OCPP_PASSWORD`, `REDIS_OCPI_PASSWORD`, `REDIS_WORKER_PASSWORD` or `REDIS_CSS_PASSWORD` is set, and passes each service its URL. `REDIS_PASSWORD` stays the password of the Redis `default` (admin) user.

**External Redis.** Create the users before you install or upgrade the chart. Redis 7 or later is required for the `%R~` read-only key rule. This prints one `ACL SETUSER` command per user. Replace each `CHANGE_ME_*` with a password (URL-safe, no commas):

```bash
awk '$1 == "user" { name = $2; $1 = $2 = ""; printf "ACL SETUSER %s reset on >CHANGE_ME_%s%s\n", name, toupper(name), $0 }' redis/acl-rules.conf
```

Run the commands with `redis-cli` as an admin user, then persist them (`ACL SAVE` with an ACL file, or `CONFIG REWRITE`). Set `secrets.redisUrls.<user>` to `redis://<user>:<password>@<host>:<port>` (or `rediss://` for TLS). To install against a Redis without ACL support, set all five URLs to the same URL.

**Rules on upgrade.** A release can add a key prefix or channel to a user. A `pre-install`/`pre-upgrade` hook job (`redisAcl.sync.enabled`, default `true`) applies `redis/acl-rules.conf` to the five users before the migration and before any Deployment changes: `ACL SETUSER <user> resetkeys resetchannels nocommands clearselectors <rules>`, so passwords stay as they are. It connects to `dependencies.redisHost` as `redisAcl.admin.user` (default `default`) with the password from `redisAcl.admin.passwordSecret` (default: the bundled Redis Secret `<release>-redis`, key `redis-password`). It persists the rules in the object the Redis loads its ACL file from at start (`redisAcl.aclFile`; default: the bundled Bitnami Secret `<release>-redis-acl`, or the ConfigMap `<release>-redis-configuration` of older Bitnami charts), else with `ACL SAVE` or `CONFIG REWRITE`. A failure stops the upgrade with the old pods running. Without the admin password Secret the job changes nothing.

With an external Redis, apply the rules of the new release before you upgrade, then persist them as above. This prints one command per user and keeps the passwords:

```bash
awk '$1 == "user" { name = $2; $1 = $2 = ""; printf "ACL SETUSER %s resetkeys resetchannels nocommands clearselectors%s\n", name, $0 }' redis/acl-rules.conf
```

Or set `redisAcl.admin` (and `redisAcl.aclFile` when the Redis loads its ACL file from a Secret or ConfigMap) so the hook does it. Managed caches that manage users through their own API (ElastiCache, Memorystore, Azure Cache) need the change there; set `redisAcl.sync.enabled: false`. The worker checks its lock key grants at start and exits with an error naming the missing grant, so a missed step fails the rollout instead of the background jobs.

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
| `appSettings.invoice.paymentTermsDays` | Days from issue to the due date of a new invoice, 0 to 365 (30 on a fresh install) |
| `appSettings.fleet.invoiceRunDay` | Day of the month, 1 to 28, from which the monthly run invoices fleets with automatic monthly invoice for the previous month (1 on a fresh install) |
| `appSettings.fleet.creditReservationCents` | Fleet credit in cents an account session reserves at its start and adds each time its cost nears the reservation, for fleets with a credit limit, 1 to 100000000 (5000 on a fresh install) |
| `appSettings.pdf.logo` | Logo on every generated PDF (invoices, credit notes, fleet invoices, reports): a PNG or SVG data URI of at most 512 KB. Empty keeps the dashboard value (the default EVtivity logo on a fresh install) |
| `appSettings.pdf.footer` | Plain text centered at the bottom of every PDF page, at most 5 lines and 500 characters, printed as written in every language. Empty keeps the dashboard value (no footer on a fresh install) |
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

### Database Connections

Each api, ocpp, ocpi, worker and css pod pools `dependencies.postgresPoolMax` connections (default 10, env `DB_POOL_MAX`). Keep the sum over all pods, with HPA at `maxReplicas` plus one migrate or seed job, below the PostgreSQL `max_connections` minus its reserved connections (stock PostgreSQL: 100 minus 3).

| Setup | Pods | Connections |
|-------|------|-------------|
| Defaults (api, ocpp, worker at 1 replica) | 3 | 30 |
| HPA at 5 api and 5 ocpp, worker, ocpi | 12 | 120 |
| HPA at 5 api, 5 ocpp, 4 worker, ocpi | 15 | 150 |

Raise `max_connections` on the database or lower the pool for the second case. The OCPP server authenticates at most half its pool of station connections at once and queues the rest, so a reconnect wave leaves connections for connected stations.

### Credential Rotation

Off by default. With `credentialRotation.enabled: true`, a CronJob rotates the PostgreSQL and Redis passwords of the services on `credentialRotation.schedule` (default 03:00 on the 1st of each month), without downtime. It needs admin credentials for both servers, so you turn it on deliberately.

**How a run works.**

1. Preflight. The job checks every connection and server setting first and changes nothing when one fails.
2. New credentials next to the old ones:
   - PostgreSQL: the services log in as one of two alternating roles, `<appUser>` and `<appUser>_clone` (default `evtivity_app`), both members of `groupRole` (`evtivity_app_group`), which holds the table, sequence and function privileges. The idle role gets a new password. The old role keeps working.
   - Redis: each service user (`api`, `ocpp`, `ocpi`, `worker`, `css`) gets a second password (`ACL SETUSER <user> >new`). The old password keeps working.
3. The job writes the new URLs to the Secret `<fullname>-credentials` and restarts the api, ocpp, ocpi, worker and css Deployments (a rolling restart, like `kubectl rollout restart`).
4. When every rollout completes, it waits `revokeDelaySeconds` (default 120) for terminating pods, then removes the old credentials: the previous PostgreSQL role loses its password, and each Redis user keeps only the new one (`resetpass`).
5. With `database.rotateOwner` (default on) it changes the owner password (the role in `secrets.databaseUrl`), which only the migrate and seed jobs use.

A run that fails before step 4 leaves the old credentials valid, and the pods keep running. The next run finishes an unfinished rollout before it rotates again. New PostgreSQL passwords are sent as SCRAM-SHA-256 verifiers, so the plain password never reaches the server or its logs. Run one rotation now with `kubectl create job --from=cronjob/<fullname>-credential-rotation rotate-now -n <namespace>`.

**The credentials Secret.** When you enable rotation, a `pre-install`/`pre-upgrade` hook copies `DATABASE_URL` and the `REDIS_URL_*` keys of the enabled services into `<fullname>-credentials` (`DATABASE_URL`, `MIGRATE_DATABASE_URL`, `REDIS_URL_*`). Helm never renders this Secret, so an upgrade cannot put back a password the job has rotated away. From then on it is the source of truth: the services read `DATABASE_URL` and their `REDIS_URL_*` from it, the migrate and seed jobs read `MIGRATE_DATABASE_URL`, and later changes to `secrets.databaseUrl` or `secrets.redisUrls` are ignored. The hook only adds keys that are missing, for example when you enable a service. `helm uninstall` keeps the Secret; `scripts/uninstall.sh` deletes it.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `credentialRotation.enabled` | `false` | Create the credentials Secret and the rotation CronJob |
| `credentialRotation.schedule` | `0 3 1 * *` | Cron schedule |
| `credentialRotation.timeZone` | `""` | IANA time zone of the schedule (empty: the controller's zone) |
| `credentialRotation.suspend` | `false` | Pause the schedule |
| `credentialRotation.rolloutTimeoutSeconds` | `900` | Time each Deployment has to finish its rollout (60 or more) |
| `credentialRotation.revokeDelaySeconds` | `120` | Wait after the rollouts before the old credentials are removed |
| `credentialRotation.database.enabled` | `true` | Rotate the PostgreSQL credentials |
| `credentialRotation.database.appUser` | `evtivity_app` | First alternating login role (the second is `<appUser>_clone`) |
| `credentialRotation.database.groupRole` | `evtivity_app_group` | Role that holds the application privileges |
| `credentialRotation.database.rotateOwner` | `true` | Also rotate the owner password |
| `credentialRotation.database.admin.user` | `postgres` | PostgreSQL admin user (superuser, or CREATEROLE with ADMIN on `groupRole`) |
| `credentialRotation.database.admin.passwordSecret.name` | `""` | Secret with the admin password (required) |
| `credentialRotation.database.admin.passwordSecret.key` | `postgres-password` | Key of the admin password |
| `credentialRotation.redis.enabled` | `true` | Rotate the Redis ACL user passwords |
| `credentialRotation.redis.admin.user` | `default` | Redis admin user (needs `ACL`, `CONFIG GET` and `INFO`) |
| `credentialRotation.redis.admin.passwordSecret.name` | `""` | Secret with the admin password (required) |
| `credentialRotation.redis.admin.passwordSecret.key` | `redis-password` | Key of the admin password |
| `credentialRotation.redis.aclFile.kind` | `Secret` | `Secret` or `ConfigMap` that holds the ACL file Redis loads at start |
| `credentialRotation.redis.aclFile.name` | `""` | Its name (required for the bundled Bitnami Redis) |
| `credentialRotation.redis.aclFile.key` | `users.acl` | Its key |
| `credentialRotation.resources`, `nodeSelector`, `tolerations`, `affinity` | | Pod settings of the jobs |

**Bundled PostgreSQL and Redis.** `CREDENTIAL_ROTATION=true ./scripts/install.sh` turns rotation on and sets the admin Secrets (`<release>-postgresql`, `<release>-redis`) and the Redis ACL file. Bitnami Redis rebuilds its ACL file at every start from `<release>-redis-acl` (Secret, chart 27 and later) or `<release>-redis-configuration` (ConfigMap, earlier charts). The job writes the rotated passwords into that object as SHA-256 hashes, so a Redis restart keeps them. It writes both passwords before the switch and only the new one after it, so a restart at any point accepts the credential the pods use. Re-running `bitnami/redis` with the install-time passwords (`helm upgrade` of the Redis release) puts the old passwords back: take the current ones from `<fullname>-credentials` first.

**External PostgreSQL.** Give the job a user that can create roles and grant `groupRole`: a superuser, or a role with `CREATEROLE` that has `ADMIN` on `groupRole` and owns or is granted the owner role (on Amazon RDS, the master user). Store its password in a Secret and set `credentialRotation.database.admin.*`. The admin password itself is not rotated.

**External Redis.** Rotation needs a single primary (ACL changes do not replicate, so the job refuses a primary with replicas, Sentinel or cluster setups) and an admin user that may run `ACL SETUSER`, `ACL GETUSER`, `ACL SAVE`, `CONFIG GET` and `INFO`. The rotated passwords must survive a restart: either Redis loads a writable `aclfile` (the job runs `ACL SAVE`), or you set `credentialRotation.redis.aclFile` to the Secret or ConfigMap it loads at start. Managed caches that manage users through their own API (ElastiCache, Memorystore, Azure Cache) are rotated by their provider: set `credentialRotation.redis.enabled: false`.

**Rotation by another system.** With Vault, External Secrets or a cloud secret manager that rotates the credentials, leave `credentialRotation.enabled: false` and let that system update your `secrets.existingSecret` and restart the Deployments.

**Failure alert.** A failed run shows as a failed Job of the CronJob (`kubectl get jobs -l app.kubernetes.io/component=credential-rotation`) and logs `[rotation] failed: <reason>`. With kube-state-metrics, alert on `kube_job_status_failed{job_name=~"<fullname>-credential-rotation-.*"} > 0`. A run that fails keeps the old credentials valid, so nothing breaks until the cause is fixed and the next run passes.

**Turning rotation on for an existing install.** Upgrade with `credentialRotation.enabled=true` and the admin settings. The hook copies the current credentials, the pods restart once against `<fullname>-credentials`, and nothing rotates until the first scheduled run. At the first run the services move from the owner role to `<appUser>`: they then hold only the privileges of `groupRole` (data, not schema changes), which is all they need, since migrations run as the owner.

**Turning rotation off.** Copy the current credentials back into your values first: `secrets.databaseUrl` from `MIGRATE_DATABASE_URL` and each `secrets.redisUrls.<service>` from `REDIS_URL_<SERVICE>` of `<fullname>-credentials`. The services then log in as the owner again. Then upgrade with `credentialRotation.enabled=false` and delete the Secret.

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

The install script generates self-signed certificates automatically. The server certificate keeps `CN=EVtivity OCPP Server` and lists the names stations connect to as subjectAltName entries, so stations that verify the hostname accept it:

- The OCPP gateway route host(s) from `gatewayAPI.routes` in `values.yaml` (default `ocpp.evtivity.local`). Set `OCPP_TLS_HOSTS` (comma-separated DNS names) to use other names, such as the DNS name of the TLS LoadBalancer.
- The IP addresses in `OCPP_TLS_IPS` (comma-separated), for stations that connect to the TLS LoadBalancer by IP.
- The in-cluster OCPP Service names (`<release>-ocpp`, `<release>-ocpp.<namespace>`, `.svc`, `.svc.cluster.local`), used by the simulator.

```bash
OCPP_TLS_HOSTS=ocpp.example.com OCPP_TLS_IPS=203.0.113.10 ./scripts/install.sh
```

Check the names with `kubectl get secret evtivity-ocpp-tls -n evtivity -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text`.

To use your own certificates:

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
