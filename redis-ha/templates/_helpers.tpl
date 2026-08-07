{{/*
Nom du chart.
*/}}
{{- define "redis-ha.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Nom complet des ressources.
*/}}
{{- define "redis-ha.fullname" -}}
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
Service headless : DNS stable des pods. Sentinel et les replicas s'annoncent
par ces noms, jamais par leur IP (qui change a chaque recreation de pod).
*/}}
{{- define "redis-ha.headlessServiceName" -}}
{{- printf "%s-headless" (include "redis-ha.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Service dedie aux sentinels (point d'entree des clients Sentinel-aware).
*/}}
{{- define "redis-ha.sentinelServiceName" -}}
{{- printf "%s-sentinel" (include "redis-ha.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Suffixe DNS des pods : <pod>.<headless>.<ns>.svc.<clusterDomain>
*/}}
{{- define "redis-ha.podHostnameSuffix" -}}
{{- printf ".%s.%s.svc.%s" (include "redis-ha.headlessServiceName" .) .Release.Namespace .Values.clusterDomain -}}
{{- end -}}

{{/*
FQDN du pod 0 : master au tout premier demarrage, quand aucun sentinel
n'est encore en mesure de repondre.
*/}}
{{- define "redis-ha.bootstrapMasterHost" -}}
{{- printf "%s-0%s" (include "redis-ha.fullname" .) (include "redis-ha.podHostnameSuffix" .) -}}
{{- end -}}

{{- define "redis-ha.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "redis-ha.labels" -}}
helm.sh/chart: {{ include "redis-ha.chart" . }}
{{ include "redis-ha.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: redis
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "redis-ha.selectorLabels" -}}
app.kubernetes.io/name: {{ include "redis-ha.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "redis-ha.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "redis-ha.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Nom du Secret contenant le mot de passe.
*/}}
{{- define "redis-ha.secretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- .Values.auth.existingSecret -}}
{{- else -}}
{{- include "redis-ha.fullname" . -}}
{{- end -}}
{{- end -}}

{{/*
Mot de passe : valeur explicite > Secret deja deploye > genere.
Le lookup evite qu'un `helm upgrade` ne change le mot de passe, ce qui
casserait la replication et l'authentification des sentinels.
*/}}
{{- define "redis-ha.password" -}}
{{- if .Values.auth.password -}}
{{- .Values.auth.password -}}
{{- else -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "redis-ha.fullname" .) -}}
{{- if and $existing $existing.data (hasKey $existing.data "redis-password") -}}
{{- index $existing.data "redis-password" | b64dec -}}
{{- else -}}
{{- randAlphaNum 32 -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Quorum Sentinel : valeur explicite, sinon majorite stricte ((N+1)/2).
*/}}
{{- define "redis-ha.sentinelQuorum" -}}
{{- if .Values.sentinel.quorum -}}
{{- .Values.sentinel.quorum -}}
{{- else -}}
{{- div (add (int .Values.replicaCount) 1) 2 -}}
{{- end -}}
{{- end -}}

{{/*
Affinite : surcharge complete, sinon anti-affinite soft/hard generee.
*/}}
{{- define "redis-ha.affinity" -}}
{{- if .Values.affinity -}}
{{- toYaml .Values.affinity -}}
{{- else if eq .Values.podAntiAffinity "hard" -}}
podAntiAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    - topologyKey: {{ .Values.podAntiAffinityTopologyKey }}
      labelSelector:
        matchLabels:
          {{- include "redis-ha.selectorLabels" . | nindent 10 }}
{{- else if eq .Values.podAntiAffinity "soft" -}}
podAntiAffinity:
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        topologyKey: {{ .Values.podAntiAffinityTopologyKey }}
        labelSelector:
          matchLabels:
            {{- include "redis-ha.selectorLabels" . | nindent 12 }}
{{- end -}}
{{- end -}}

{{/*
Variables d'environnement communes aux conteneurs redis et sentinel.
REDISCLI_AUTH est lu directement par redis-cli : les probes et les scripts
n'ont donc jamais a passer le mot de passe en argument (visible dans `ps`).
*/}}
{{- define "redis-ha.commonEnv" -}}
- name: MY_POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: MY_POD_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
{{- if .Values.auth.enabled }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "redis-ha.secretName" . }}
      key: redis-password
- name: REDISCLI_AUTH
  valueFrom:
    secretKeyRef:
      name: {{ include "redis-ha.secretName" . }}
      key: redis-password
{{- end }}
{{- end -}}

{{/*
Montages communs aux conteneurs redis et sentinel.
*/}}
{{- define "redis-ha.commonVolumeMounts" -}}
- name: scripts
  mountPath: /opt/redis/scripts
  readOnly: true
- name: config
  mountPath: /opt/redis/config
  readOnly: true
- name: run
  mountPath: /opt/redis/run
- name: data
  mountPath: /data
{{- end -}}

{{/*
Convertit une quantite Kubernetes (1Gi, 512Mi, 2G, 1000000) en octets.
*/}}
{{- define "redis-ha.toBytes" -}}
{{- $q := . | toString -}}
{{- $unit := regexFind "[A-Za-z]+$" $q -}}
{{- $num := float64 (regexReplaceAll "[A-Za-z]+$" $q "") -}}
{{- $mult := 1.0 -}}
{{- if eq $unit "Ki" -}}{{- $mult = 1024.0 -}}
{{- else if eq $unit "Mi" -}}{{- $mult = 1048576.0 -}}
{{- else if eq $unit "Gi" -}}{{- $mult = 1073741824.0 -}}
{{- else if eq $unit "Ti" -}}{{- $mult = 1099511627776.0 -}}
{{- else if eq $unit "k" -}}{{- $mult = 1000.0 -}}
{{- else if eq $unit "M" -}}{{- $mult = 1000000.0 -}}
{{- else if eq $unit "G" -}}{{- $mult = 1000000000.0 -}}
{{- else if eq $unit "T" -}}{{- $mult = 1000000000000.0 -}}
{{- end -}}
{{- printf "%d" (int64 (mulf $num $mult)) -}}
{{- end -}}

{{/*
Limite memoire declaree pour le conteneur redis ("" si aucune).
*/}}
{{- define "redis-ha.memoryLimit" -}}
{{- if and .Values.resources .Values.resources.limits -}}
{{- .Values.resources.limits.memory | default "" -}}
{{- end -}}
{{- end -}}

{{/*
Valeur de maxmemory a ecrire dans redis.conf ("" si indeterminable).
*/}}
{{- define "redis-ha.maxMemory" -}}
{{- if eq .Values.maxMemory.type "absolute" -}}
{{- .Values.maxMemory.value -}}
{{- else -}}
{{- $limit := include "redis-ha.memoryLimit" . -}}
{{- if $limit -}}
{{- mulf (float64 (include "redis-ha.toBytes" $limit)) (float64 .Values.maxMemory.value) | int64 -}}
{{- end -}}
{{- end -}}
{{- end -}}
