{{/*
Every long-running workload in this chart is one of two shapes: a Deployment or
a StatefulSet, with a single container. The differences between server, frontend,
the three workers and the datastores are data, not structure, so they live in
.Values.workloads and the structure lives here once.
*/}}

{{/* Image reference. registry defaults to the shared ECR one; set registry: ""
     on a workload to pull from Docker Hub. tag falls back to .Chart.AppVersion. */}}
{{- define "planpal.image" -}}
{{- $reg := .root.Values.image.registry -}}
{{- /* hasKey, not default: an explicit registry: "" must survive. */}}
{{- if hasKey .w "registry" }}{{ $reg = .w.registry }}{{ end -}}
{{- $tag := .w.tag | default .root.Values.image.tag | default .root.Chart.AppVersion -}}
{{- if $reg }}{{ printf "%s/%s:%s" $reg .w.image $tag }}
{{- else }}{{ printf "%s:%s" .w.image $tag }}{{ end -}}
{{- end -}}

{{/* How a probe reaches the container: HTTP by default, exec for the datastores. */}}
{{- define "planpal.probeHandler" -}}
{{- if .exec }}
exec:
  command:
    {{- toYaml .exec | nindent 4 }}
{{- else }}
httpGet: { path: {{ .path }}, port: {{ .port }} }
{{- end }}
{{- end -}}

{{/* Both probes from one spec. Readiness gates traffic, liveness restarts the
     container, so liveness is always the slower and more forgiving of the two. */}}
{{- define "planpal.probes" -}}
readinessProbe:
  {{- include "planpal.probeHandler" . | nindent 2 }}
  initialDelaySeconds: {{ dig "readiness" "initialDelaySeconds" 5 . }}
  periodSeconds: {{ dig "readiness" "periodSeconds" 10 . }}
livenessProbe:
  {{- include "planpal.probeHandler" . | nindent 2 }}
  initialDelaySeconds: {{ dig "liveness" "initialDelaySeconds" 15 . }}
  periodSeconds: {{ dig "liveness" "periodSeconds" 20 . }}
{{- end -}}

{{/* Deployment or StatefulSet. Expects (dict "root" $ "name" <key> "w" <spec>). */}}
{{- define "planpal.workload" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- $w := .w -}}
{{- $kind := $w.kind | default "Deployment" -}}
apiVersion: apps/v1
kind: {{ $kind }}
metadata:
  name: {{ $name }}
  labels:
    {{- include "planpal.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $name }}
spec:
  replicas: {{ $w.replicas | default 1 }}
  {{- if eq $kind "StatefulSet" }}
  serviceName: {{ $name }}
  {{- else if eq ($w.strategy | default "") "RollingUpdate" }}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      {{- /* maxUnavailable 0 keeps every old Pod serving until a new one is
             Ready, which is what makes the rollout zero-downtime. */}}
      maxUnavailable: 0
      maxSurge: 1
  {{- else if eq ($w.strategy | default "") "Recreate" }}
  {{- /* For a single-replica workload where two copies must never overlap:
         a worker that would double-process, or an in-cluster datastore. */}}
  strategy:
    type: Recreate
  {{- else }}
  {{- /* Unset: Kubernetes' own default (25%/25%). */}}
  {{- end }}
  {{- /* The selector stays a bare `app: <name>`. It is immutable on a live
         object, so switching to app.kubernetes.io/* labels here would force an
         uninstall. The standard labels go on metadata, where they are free. */}}
  selector:
    matchLabels: { app: {{ $name }} }
  template:
    metadata:
      labels: { app: {{ $name }} }
      {{- if $w.configMaps }}
      annotations:
        {{- /* Rolls this workload when non-secret config changes. Without it a
               ConfigMap edit updates etcd and nothing restarts. */}}
        checksum/config: {{ include (print $root.Template.BasePath "/configmap.yaml") $root | sha256sum }}
      {{- end }}
    spec:
      {{- with $w.serviceAccount }}
      serviceAccountName: {{ . }}
      {{- end }}
      containers:
        - name: {{ $name }}
          image: {{ include "planpal.image" (dict "root" $root "w" $w) }}
          imagePullPolicy: {{ $root.Values.image.pullPolicy }}
          {{- with $w.command }}
          command: {{ toYaml . | nindent 12 }}
          {{- end }}
          {{- with $w.args }}
          args: {{ toYaml . | nindent 12 }}
          {{- end }}
          {{- with $w.ports }}
          ports:
            {{- range . }}
            - containerPort: {{ . }}
            {{- end }}
          {{- end }}
          {{- if or $w.configMaps $w.secrets }}
          envFrom:
            {{- range $w.configMaps }}
            - configMapRef: { name: {{ . }} }
            {{- end }}
            {{- range $w.secrets }}
            - secretRef: { name: {{ . }} }
            {{- end }}
          {{- end }}
          {{- with $w.preStopSleep }}
          lifecycle:
            preStop:
              {{- /* Delays SIGTERM so kube-proxy on every node has time to drop
                     this Pod from the Service before it stops accepting work. */}}
              exec: { command: ["sleep", "{{ . }}"] }
          {{- end }}
          {{- with $w.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $w.probe }}
          {{- include "planpal.probes" . | nindent 10 }}
          {{- end }}
          {{- with $w.persistence }}
          volumeMounts:
            - name: {{ .name }}
              mountPath: {{ .mountPath }}
          {{- end }}
  {{- with $w.persistence }}
  volumeClaimTemplates:
    - metadata:
        name: {{ .name }}
      spec:
        accessModes: ["ReadWriteOnce"]
        {{- /* Named explicitly: this cluster has no default StorageClass, and
               gp2 still points at the in-tree provisioner removed in 1.27. */}}
        storageClassName: {{ .storageClass }}
        resources:
          requests:
            storage: {{ .size }}
  {{- end }}
{{- end -}}

{{/* ClusterIP Service. Expects (dict "root" $ "name" <key> "svc" <spec>). */}}
{{- define "planpal.service" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- $svc := .svc -}}
apiVersion: v1
kind: Service
metadata:
  {{- /* name defaults to the workload key; the frontend overrides it because
         the Ingress already points at "frontend-service". */}}
  name: {{ $svc.name | default $name }}
  labels:
    {{- include "planpal.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $name }}
spec:
  {{- if $svc.headless }}
  {{- /* Headless: gives each Pod a stable DNS name instead of load balancing. */}}
  clusterIP: None
  {{- else }}
  type: ClusterIP
  {{- end }}
  selector: { app: {{ $name }} }
  ports:
    {{- range $svc.ports }}
    - port: {{ .port }}
      targetPort: {{ .targetPort | default .port }}
      {{- with .name }}
      name: {{ . }}
      {{- end }}
    {{- end }}
{{- end -}}

{{/* HPA. Needs metrics-server; without it TARGETS shows <unknown> and nothing
     scales, silently. Expects (dict "root" $ "name" <key> "w" <spec>). */}}
{{- define "planpal.hpa" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- $w := .w -}}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ $name }}-hpa
  labels:
    {{- include "planpal.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $name }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: {{ $w.kind | default "Deployment" }}
    name: {{ $name }}
  minReplicas: {{ $w.hpa.minReplicas }}
  maxReplicas: {{ $w.hpa.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ $w.hpa.targetCPUUtilizationPercentage }}
{{- end -}}

{{/* PDB. Guards voluntary disruptions only: kubectl drain, node upgrades. Not
     consulted during a rolling update, which maxUnavailable governs. */}}
{{- define "planpal.pdb" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- $w := .w -}}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ $name }}-pdb
  labels:
    {{- include "planpal.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $name }}
spec:
  minAvailable: {{ $w.pdb.minAvailable }}
  selector:
    matchLabels: { app: {{ $name }} }
{{- end -}}
