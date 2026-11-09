{{/*
Expand the name of the chart.
*/}}
{{- define "detectflow.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name.
*/}}
{{- define "detectflow.fullname" -}}
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
Chart name and version, as used in the helm.sh/chart label (+ -> _).
*/}}
{{- define "detectflow.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels. Pass the component name as the dict key "component":
{{ include "detectflow.labels" (dict "ctx" . "component" "backend") }}
*/}}
{{- define "detectflow.labels" -}}
helm.sh/chart: {{ include "detectflow.chart" .ctx }}
{{ include "detectflow.selectorLabels" (dict "ctx" .ctx "component" .component) }}
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service | quote }}
app.kubernetes.io/part-of: detectflow
{{- end }}

{{/*
Selector labels  stable subset only (never includes version).
*/}}
{{- define "detectflow.selectorLabels" -}}
app.kubernetes.io/name: {{ include "detectflow.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Image pull secrets block.
*/}}
{{- define "detectflow.imagePullSecrets" -}}
{{- if .Values.imagePullSecrets -}}
imagePullSecrets:
{{- toYaml .Values.imagePullSecrets | nindent 0 }}
{{- end -}}
{{- end -}}

{{/*
Assemble a "repository:tag" image reference from an image dict.
Usage: {{ include "detectflow.image" .Values.backend.image }}
*/}}
{{- define "detectflow.image" -}}
{{- printf "%s:%s" .repository .tag -}}
{{- end -}}

{{/*
Single source of truth for the effective PVC name. Resolves an `existingClaim`
override when one is set, else the chart's default name. Every place that
references a PVC by name - the PVC resource itself, the pod's claimName, and
the chart-computed FLINK_*_PVC keys the backend reads - must go through this
helper, so a rename can never happen in only one spot.
Usage: {{ include "detectflow.pvcName" (dict "ctx" . "which" "checkpoints") }}
*/}}
{{- define "detectflow.pvcName" -}}
{{- $defaults := dict "metrics" "admin-panel-metrics-pvc" "checkpoints" "flink-checkpoints-pvc" "ha" "flink-ha-pvc" "savepoints" "flink-savepoints-pvc" -}}
{{- $pvcs := .ctx.Values.flink.pvcs -}}
{{- $overrides := dict "metrics" .ctx.Values.backend.persistence.existingClaim "checkpoints" $pvcs.existingCheckpointsClaim "ha" $pvcs.existingHaClaim "savepoints" $pvcs.existingSavepointsClaim -}}
{{- index $overrides .which | default (index $defaults .which) -}}
{{- end -}}
