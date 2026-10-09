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
Connection credentials of one service. REDIS_URL comes from the service's own
key (REDIS_URL_API, REDIS_URL_OCPP, REDIS_URL_OCPI, REDIS_URL_WORKER,
REDIS_URL_CSS): each service connects to Redis as its own ACL user
(redis/acl-rules.conf). With credentialRotation.enabled, DATABASE_URL and
REDIS_URL come from the credentials Secret instead of the chart Secret. Explicit
env entries win over the Secret's envFrom. With redisTls.enabled it also sets
REDIS_TLS_CA_PEM, the CA that signed the Redis server certificate, which the
services trust for rediss://.
Usage: include "evtivity-csms.credentialsEnv" (dict "context" . "component" "api")
*/}}
{{- define "evtivity-csms.credentialsEnv" -}}
{{- $secret := include "evtivity-csms.secretName" .context -}}
{{- if .context.Values.credentialRotation.enabled -}}
{{- $secret = include "evtivity-csms.credentialsSecretName" .context -}}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: DATABASE_URL
{{ end -}}
- name: REDIS_URL
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: REDIS_URL_{{ upper .component }}
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
      {{- if .Values.credentialRotation.enabled }}
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
