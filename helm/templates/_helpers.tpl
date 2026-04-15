{{/*
Expand the name of the chart.
*/}}
{{- define "windrose-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name.
*/}}
{{- define "windrose-server.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Chart label.
*/}}
{{- define "windrose-server.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels.
*/}}
{{- define "windrose-server.labels" -}}
helm.sh/chart: {{ include "windrose-server.chart" . }}
{{ include "windrose-server.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels.
*/}}
{{- define "windrose-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "windrose-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
ServiceAccount name.
*/}}
{{- define "windrose-server.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "windrose-server.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
PVC name (honors existingClaim).
*/}}
{{- define "windrose-server.pvcName" -}}
{{- if .Values.persistence.existingClaim -}}
{{- .Values.persistence.existingClaim -}}
{{- else -}}
{{- include "windrose-server.fullname" . -}}
{{- end -}}
{{- end -}}

{{/*
Password Secret name (honors existingSecret).
*/}}
{{- define "windrose-server.passwordSecretName" -}}
{{- if .Values.windrose.server.password.existingSecret -}}
{{- .Values.windrose.server.password.existingSecret -}}
{{- else -}}
{{- printf "%s-password" (include "windrose-server.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Emit a `- name: X\n  value: "Y"` env pair only when the value is non-empty
and non-nil. Call with (list "VAR_NAME" .Value).
*/}}
{{- define "windrose-server.stringEnv" -}}
{{- $name := index . 0 -}}
{{- $value := index . 1 -}}
{{- if and (ne (kindOf $value) "invalid") (ne (toString $value) "") }}
- name: {{ $name }}
  value: {{ $value | quote }}
{{- end -}}
{{- end -}}

{{/*
Emit env pair for a value that may legitimately be `false` — render whenever
it is not nil.
*/}}
{{- define "windrose-server.explicitEnv" -}}
{{- $name := index . 0 -}}
{{- $value := index . 1 -}}
{{- if ne (kindOf $value) "invalid" }}
- name: {{ $name }}
  value: {{ $value | quote }}
{{- end -}}
{{- end -}}
