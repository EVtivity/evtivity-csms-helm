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
Init containers that wait for PostgreSQL and Redis to be ready.
Uses dependencies.postgresHost/redisHost from values.yaml.
*/}}
{{- define "evtivity-csms.waitForDeps" -}}
- name: wait-for-postgres
  image: busybox:1.37
  command: ['sh', '-c', 'until nc -z {{ .Values.dependencies.postgresHost }} {{ .Values.dependencies.postgresPort }}; do echo "waiting for postgres..."; sleep 2; done']
- name: wait-for-redis
  image: busybox:1.37
  command: ['sh', '-c', 'until nc -z {{ .Values.dependencies.redisHost }} {{ .Values.dependencies.redisPort }}; do echo "waiting for redis..."; sleep 2; done']
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
