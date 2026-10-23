{{/*
Expand the name of the chart.
*/}}
{{- define "evtivity-csms.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "evtivity-csms.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "evtivity-csms.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "evtivity-csms.labels" -}}
helm.sh/chart: {{ include "evtivity-csms.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: evtivity-csms
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end }}

{{/*
Component labels (call with dict "context" $ "component" "api")
*/}}
{{- define "evtivity-csms.componentLabels" -}}
{{ include "evtivity-csms.labels" .context }}
app.kubernetes.io/name: {{ include "evtivity-csms.name" .context }}-{{ .component }}
app.kubernetes.io/instance: {{ .context.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Component selector labels
*/}}
{{- define "evtivity-csms.componentSelectorLabels" -}}
app.kubernetes.io/name: {{ include "evtivity-csms.name" .context }}-{{ .component }}
app.kubernetes.io/instance: {{ .context.Release.Name }}
{{- end }}

{{/*
Secret name
*/}}
{{- define "evtivity-csms.secretName" -}}
{{- if .Values.secrets.existingSecret }}
{{- .Values.secrets.existingSecret }}
{{- else }}
{{- include "evtivity-csms.fullname" . }}-secrets
{{- end }}
{{- end }}

{{/*
Name of the credentials Secret that the rotation job owns (credentialRotation).
Helm never renders it, so an upgrade cannot put back a rotated-away password.
*/}}
{{- define "evtivity-csms.credentialsSecretName" -}}
{{- include "evtivity-csms.fullname" . }}-credentials
{{- end }}

{{/*
Effective credentialRotation values as YAML. helm upgrade --reuse-values keeps
the values of the installed chart, and charts before 0.1.43 have no
credentialRotation block, so every key is read with dig and the default from
values.yaml. Keep these defaults in step with values.yaml.
Usage: {{- $r := include "evtivity-csms.credentialRotation" . | fromYaml }}
*/}}
{{- define "evtivity-csms.credentialRotation" -}}
{{- $v := .Values.credentialRotation | default dict -}}
{{- $r := dict
  "enabled" (dig "enabled" false $v)
  "schedule" (dig "schedule" "0 3 1 * *" $v)
  "timeZone" (dig "timeZone" "" $v)
  "suspend" (dig "suspend" false $v)
  "rolloutTimeoutSeconds" (dig "rolloutTimeoutSeconds" 900 $v)
  "revokeDelaySeconds" (dig "revokeDelaySeconds" 120 $v)
  "database" (dict
    "enabled" (dig "database" "enabled" true $v)
    "appUser" (dig "database" "appUser" "evtivity_app" $v)
    "groupRole" (dig "database" "groupRole" "evtivity_app_group" $v)
    "rotateOwner" (dig "database" "rotateOwner" true $v)
    "admin" (dict
      "user" (dig "database" "admin" "user" "postgres" $v)
      "passwordSecret" (dict
        "name" (dig "database" "admin" "passwordSecret" "name" "" $v)
        "key" (dig "database" "admin" "passwordSecret" "key" "postgres-password" $v))))
  "redis" (dict
    "enabled" (dig "redis" "enabled" true $v)
    "admin" (dict
      "user" (dig "redis" "admin" "user" "default" $v)
      "passwordSecret" (dict
        "name" (dig "redis" "admin" "passwordSecret" "name" "" $v)
        "key" (dig "redis" "admin" "passwordSecret" "key" "redis-password" $v)))
    "aclFile" (dict
      "kind" (dig "redis" "aclFile" "kind" "Secret" $v)
      "name" (dig "redis" "aclFile" "name" "" $v)
      "key" (dig "redis" "aclFile" "key" "users.acl" $v)))
  "resources" (dig "resources" (dict
    "requests" (dict "cpu" "50m" "memory" "128Mi")
    "limits" (dict "cpu" "500m" "memory" "256Mi")) $v)
  "nodeSelector" (dig "nodeSelector" dict $v)
  "tolerations" (dig "tolerations" list $v)
  "affinity" (dig "affinity" dict $v)
-}}
{{- toYaml $r -}}
{{- end }}

{{/*
Services that connect to PostgreSQL and Redis, as a comma-separated list of the
enabled ones (api, ocpp, ocpi, worker, css).
*/}}
{{- define "evtivity-csms.credentialComponents" -}}
{{- $enabled := list }}
{{- range $component := list "api" "ocpp" "ocpi" "worker" "css" }}
{{- if (index $.Values $component).enabled }}
{{- $enabled = append $enabled $component }}
{{- end }}
{{- end }}
{{- join "," $enabled }}
{{- end }}

{{/*
Secret environment of one service, key by key (secretKeyRef, never envFrom): a pod
gets only the keys it uses, so a compromised pod cannot read another service's
Redis password, sign tokens or decrypt settings it never needs (SH-M21).
DATABASE_URL, and REDIS_URL from the service's own key (REDIS_URL_API,
REDIS_URL_OCPP, REDIS_URL_OCPI, REDIS_URL_WORKER, REDIS_URL_CSS): each service
connects to Redis as its own ACL user (redis/acl-rules.conf). With
credentialRotation.enabled both come from the credentials Secret instead of the
chart Secret. "keys" lists the other chart Secret keys the service reads
(JWT_SECRET, SETTINGS_ENCRYPTION_KEY). With redisTls.enabled it also sets
REDIS_TLS_CA_PEM, the CA that signed the Redis server certificate, which the
services trust for rediss://.
Usage: include "evtivity-csms.credentialsEnv" (dict "context" . "component" "api" "keys" (list "JWT_SECRET"))
*/}}
{{- define "evtivity-csms.credentialsEnv" -}}
{{- $chartSecret := include "evtivity-csms.secretName" .context -}}
{{- $secret := $chartSecret -}}
{{- if (.context.Values.credentialRotation | default dict).enabled -}}
{{- $secret = include "evtivity-csms.credentialsSecretName" .context -}}
{{- end -}}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: DATABASE_URL
- name: REDIS_URL
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: REDIS_URL_{{ upper .component }}
{{- range $key := (.keys | default list) }}
- name: {{ $key }}
  valueFrom:
    secretKeyRef:
      name: {{ $chartSecret }}
      key: {{ $key }}
{{- end }}
{{- if .context.Values.redisTls.enabled }}
- name: REDIS_TLS_CA_PEM
  valueFrom:
    secretKeyRef:
      name: {{ required "redisTls.caSecret is required when redisTls.enabled is true" .context.Values.redisTls.caSecret }}
      key: {{ .context.Values.redisTls.caKey }}
{{- end }}
{{- end }}

{{/*
DATABASE_URL of the migrate and seed jobs: the database owner. With
credentialRotation.enabled it is MIGRATE_DATABASE_URL of the credentials Secret.
*/}}
{{- define "evtivity-csms.ownerDatabaseUrlEnv" -}}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      {{- if (.Values.credentialRotation | default dict).enabled }}
      name: {{ include "evtivity-csms.credentialsSecretName" . }}
      key: MIGRATE_DATABASE_URL
      {{- else }}
      name: {{ include "evtivity-csms.secretName" . }}
      key: DATABASE_URL
      {{- end }}
{{- end }}

{{/*
ConfigMap name
*/}}
{{- define "evtivity-csms.configMapName" -}}
{{- include "evtivity-csms.fullname" . }}-config
{{- end }}

{{/*
Image for a component.
Usage: {{ include "evtivity-csms.image" (dict "context" $ "component" "api" "values" .Values.api) }}
*/}}
{{- define "evtivity-csms.image" -}}
{{- $registry := .context.Values.image.registry -}}
{{- $tag := default (default .context.Chart.AppVersion .context.Values.image.tag) .values.image.tag -}}
{{- $repository := .values.image.repository -}}
{{- if $repository -}}
{{- printf "%s:%s" $repository $tag -}}
{{- else -}}
{{- printf "%s/%s:%s" $registry .component $tag -}}
{{- end -}}
{{- end }}

{{/*
Image pull policy
*/}}
{{- define "evtivity-csms.imagePullPolicy" -}}
{{- .Values.image.pullPolicy | default "IfNotPresent" }}
{{- end }}

{{/*
App settings sensitive Secret name
*/}}
{{- define "evtivity-csms.appSettingsSensitiveSecretName" -}}
{{- if .Values.appSettings.sensitive.existingSecret }}
{{- .Values.appSettings.sensitive.existingSecret }}
{{- else }}
{{- include "evtivity-csms.fullname" . }}-app-settings-sensitive
{{- end }}
{{- end }}

{{/*
"true" when a proxy list entry is an IPv6 CIDR of prefix 96 or less that starts
with a zero group (::/80, ::ffff:0.0.0.0/96, 0:0::/64): such a range holds the
IPv4-mapped addresses, and the proxy check compares an IPv4 peer in that form,
so it trusts every IPv4 peer (security review R2-L2). Real proxy ranges never
start with a zero group. Empty otherwise.
*/}}
{{- define "evtivity-csms.trustsEveryIpv4" -}}
{{- if regexMatch "^(?i)(::|0{1,4}:)[0-9a-f:.]*/[0-9]+$" . -}}
{{- if le (atoi (regexFind "[0-9]+$" .)) 96 }}true{{ end -}}
{{- end -}}
{{- end }}

{{/*
The init container image, pinned by digest (the busybox 1.37 index, the same
pin as the CSMS CI build context check).
*/}}
{{- define "evtivity-csms.initImage" -}}
busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e
{{- end }}

{{/*
Init containers that wait for PostgreSQL and Redis to be ready.
Uses dependencies.postgresHost/redisHost from values.yaml.
*/}}
{{- define "evtivity-csms.waitForDeps" -}}
- name: wait-for-postgres
  image: {{ include "evtivity-csms.initImage" . }}
  securityContext:
    {{- include "evtivity-csms.containerSecurityContext" . | nindent 4 }}
  command: ['sh', '-c', 'until nc -z {{ .Values.dependencies.postgresHost }} {{ .Values.dependencies.postgresPort }}; do echo "waiting for postgres..."; sleep 2; done']
- name: wait-for-redis
  image: {{ include "evtivity-csms.initImage" . }}
  securityContext:
    {{- include "evtivity-csms.containerSecurityContext" . | nindent 4 }}
  command: ['sh', '-c', 'until nc -z {{ .Values.dependencies.redisHost }} {{ .Values.dependencies.redisPort }}; do echo "waiting for redis..."; sleep 2; done']
{{- end }}

{{/*
Security headers of the CSMS and portal pages (SH-M20), the same as the images'
packages/<app>/nginx-security-headers.conf: change both together. Included in
every location of the nginx ConfigMaps, because nginx drops server-level
add_header in a location that sets its own. frame-ancestors works only as a
header. Referrer-Policy keeps the origin: Google Maps keys restricted by referrer
need it. Browsers apply HSTS only on responses that reached them over HTTPS.
Usage: include "evtivity-csms.nginxSecurityHeaders" "csms" (or "portal")
*/}}
{{- define "evtivity-csms.nginxSecurityHeaders" -}}
{{- $csp := "default-src 'self'; script-src 'self' https://www.google.com/recaptcha/ https://www.gstatic.com/recaptcha/ https://www.googletagmanager.com https://maps.googleapis.com https://js.stripe.com https://m.stripe.network https://*.adyen.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data: blob: https://maps.gstatic.com https://maps.googleapis.com https://*.ggpht.com https://*.googleusercontent.com https://*.amazonaws.com https://*.stripe.com https://*.adyen.com; connect-src 'self' http: https:; frame-src 'self' https://www.google.com/recaptcha/ https://www.google.com/maps/ https://js.stripe.com https://hooks.stripe.com https://m.stripe.network https:; object-src 'none'; base-uri 'self'; form-action 'self' https:; frame-ancestors 'none'" -}}
{{- if eq . "portal" -}}
{{- $csp = "default-src 'self'; script-src 'self' https://www.google.com/recaptcha/ https://www.gstatic.com/recaptcha/ https://www.googletagmanager.com https://js.stripe.com https://m.stripe.network https://maps.googleapis.com https://*.adyen.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data: https://*.stripe.com https://maps.gstatic.com https://maps.googleapis.com https://*.ggpht.com https://*.googleusercontent.com https://*.amazonaws.com https://*.adyen.com; connect-src 'self' http: https:; frame-src 'self' https://www.google.com/recaptcha/ https://js.stripe.com https://hooks.stripe.com https://m.stripe.network https:; object-src 'none'; base-uri 'self'; form-action 'self' https:; frame-ancestors 'none'" -}}
{{- end -}}
add_header Content-Security-Policy "{{ $csp }}" always;
add_header X-Frame-Options "DENY" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Strict-Transport-Security "max-age=31536000" always;
{{- end }}

{{/*
Install warnings of NOTES.txt about values that leave an install weaker than it
looks: a gateway without HTTPS, and no trusted proxy for the API or OCPP behind
the gateway. Empty when none applies. internal-scripts/helm-check.sh renders it.
*/}}
{{- define "evtivity-csms.deploymentWarnings" -}}
{{- if and .Values.gatewayAPI.enabled .Values.gatewayAPI.gateway.create }}
{{- $https := false }}
{{- range .Values.gatewayAPI.gateway.listeners }}{{ if eq .protocol "HTTPS" }}{{ $https = true }}{{ end }}{{ end }}
{{- if not $https }}

WARNING: the Gateway has no HTTPS listener. Sign-in cookies, passwords and station
Basic Auth credentials travel unencrypted. Add an HTTPS listener with a certificate
(gatewayAPI.gateway.listeners) before you use this install outside a test network.
{{- end }}
{{- end }}

{{- if and .Values.gatewayAPI.enabled (not .Values.api.env.trustProxy) }}

WARNING: api.env.trustProxy is empty. Behind the gateway the API sees every request
as plain HTTP from the gateway address: sign-in cookies get no Secure flag and all
clients share one rate limit. Set it to the gateway pod range.
{{- end }}

{{- if and .Values.ocpp.enabled .Values.gatewayAPI.enabled (not .Values.ocpp.env.trustedProxyCidrs) }}

WARNING: ocpp.env.trustedProxyCidrs is empty. Stations reach the OCPP server through
the gateway, so the per-IP connection limits count every station as the gateway
address. Set it to the gateway pod range.
{{- end }}

{{- end }}

{{/*
Pod security context of every workload (SH-M23, the Pod Security "restricted"
profile): non-root as the image's own user, RuntimeDefault seccomp, and the
volume group of that user. uid: node images 1000, nginx-unprivileged 101,
Grafana 472, Prometheus 65534, Loki 10001, Alloy 473.
Usage: include "evtivity-csms.podSecurityContext" (dict "uid" 1000)
*/}}
{{- define "evtivity-csms.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: {{ .uid }}
runAsGroup: {{ .uid }}
fsGroup: {{ .uid }}
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/*
Container security context of every container: no privilege escalation, no
capabilities, read-only root filesystem (writable paths are emptyDir volumes,
/tmp in every pod).
*/}}
{{- define "evtivity-csms.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end }}

{{/*
Pod and container security context of the credential rotation jobs. They run
the migrate image as its unprivileged node user (uid 1000) and write no files.
*/}}
{{- define "evtivity-csms.rotationPodSecurityContext" -}}
runAsNonRoot: true
runAsUser: 1000
runAsGroup: 1000
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "evtivity-csms.rotationContainerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end }}

{{/*
The NOTES.txt line about the portal passkey relying party, or empty. It reads the
host of PORTAL_URL as the ConfigMap renders it, the URL the API builds the portal
relying party from. Only while api.env.webauthnRpId is set.
*/}}
{{- define "evtivity-csms.passkeyPortalNote" -}}
{{- $webauthnRpId := .Values.api.env.webauthnRpId | default "" | toString | trim | lower }}
{{- if ne $webauthnRpId "" }}
{{- $config := include (print $.Template.BasePath "/configmap.yaml") . | fromYaml }}
{{- $portalUrl := get ($config.data | default dict) "PORTAL_URL" | default "" | toString }}
{{- $portalHost := "" }}
{{- if $portalUrl }}{{ $portalHost = (urlParse $portalUrl).hostname | lower }}{{ end }}
{{- if and $portalHost (or (contains ":" $portalHost) (regexMatch "(^|\\.)[0-9]+$" $portalHost)) }}
{{- printf "the portal is served from the IP address %s, where browsers refuse passkeys, so drivers cannot use them. Serve the portal on a domain name to offer them." $portalHost }}
{{- else if and $portalHost (ne $portalHost $webauthnRpId) (not (hasSuffix (printf ".%s" $webauthnRpId) $portalHost)) }}
{{- printf "api.env.webauthnRpId %s is not the portal host %s or a parent domain of it, so the portal uses %s as its passkey relying party. Drivers and operators keep separate passkeys." $webauthnRpId $portalHost $portalHost }}
{{- end }}
{{- end }}
{{- end }}
