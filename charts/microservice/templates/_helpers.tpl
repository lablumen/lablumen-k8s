{{/*
Canonical service name. Required: set .Values.name in services/<svc>/values.yaml.
*/}}
{{- define "microservice.name" -}}
{{- $name := .Values.name | default "" -}}
{{- if not $name -}}
{{- fail "microservice: .Values.name is required (set it in services/<svc>/values.yaml)" -}}
{{- end -}}
{{- $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fullname = the canonical service name (services are uniquely named; env separation is by namespace).
*/}}
{{- define "microservice.fullname" -}}
{{- include "microservice.name" . -}}
{{- end -}}

{{- define "microservice.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Standard labels.
*/}}
{{- define "microservice.labels" -}}
helm.sh/chart: {{ include "microservice.chart" . }}
{{ include "microservice.selectorLabels" . }}
{{- if .Values.image.tag }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: lablumen
{{- end -}}

{{/*
Selector labels (immutable subset).
*/}}
{{- define "microservice.selectorLabels" -}}
app.kubernetes.io/name: {{ include "microservice.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
ServiceAccount name.
*/}}
{{- define "microservice.serviceAccountName" -}}
{{- .Values.serviceAccount.name | default (include "microservice.name" .) -}}
{{- end -}}

{{/*
ESO target Secret name.
*/}}
{{- define "microservice.secretName" -}}
{{- .Values.externalSecret.secretName | default (printf "%s-secrets" (include "microservice.name" .)) -}}
{{- end -}}
