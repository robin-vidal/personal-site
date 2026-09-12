{{- define "personal-site.name" -}}
{{- .Chart.Name }}
{{- end }}

{{- define "personal-site.fullname" -}}
{{- .Release.Name }}-{{ .Chart.Name }}
{{- end }}

{{- define "personal-site.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "personal-site.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "personal-site.selectorLabels" -}}
app.kubernetes.io/name: {{ include "personal-site.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
