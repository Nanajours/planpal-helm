
{{- define "planpal.image" -}}
{{- $reg := .root.Values.image.registry -}}
{{- if hasKey .w "registry" }}{{ $reg = .w.registry }}{{ end -}}
{{- $tag := .w.tag | default .root.Values.image.tag | default .root.Chart.AppVersion -}}
{{- if $reg }}{{ printf "%s/%s:%s" $reg .w.image $tag }}
{{- else }}{{ printf "%s:%s" .w.image $tag }}{{ end -}}
{{- end -}}

{{- define "planpal.probeHandler" -}}
{{- if .exec -}}
exec:
  command:
    {{- toYaml .exec | nindent 4 }}
{{- else -}}
httpGet: { path: {{ .path }}, port: {{ .port }} }
{{- end -}}
{{- end -}}

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

{{- define "planpal.workload" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- $w := .w -}}
{{- $kind := $w.kind | default "Deployment" -}}
{{- $isRollout := and $w.rollout $w.rollout.enabled -}}
{{- if $isRollout }}
apiVersion: argoproj.io/v1alpha1
kind: Rollout
{{- else }}
apiVersion: apps/v1
kind: {{ $kind }}
{{- end }}
metadata:
  name: {{ $name }}
  labels:
    {{- include "planpal.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $name }}
spec:
  replicas: {{ $w.replicas | default 1 }}
  {{- if $isRollout }}
  strategy:
    {{- if eq ($w.rollout.strategy | default "blueGreen") "canary" }}
    canary:
      steps:
        {{- range $w.rollout.steps }}
        {{- if .setWeight }}
        - setWeight: {{ .setWeight }}
        {{- end }}
        {{- if .pause }}
        - pause: {{ toYaml .pause | nindent 12 }}
        {{- end }}
        {{- end }}
    {{- else }}
    blueGreen:
      activeService: {{ $w.rollout.activeService | default $name }}
      previewService: {{ $w.rollout.previewService | default (printf "%s-preview" $name) }}
      autoPromotionEnabled: {{ $w.rollout.autoPromotionEnabled | default false }}
      {{- with $w.rollout.scaleDownDelaySeconds }}
      scaleDownDelaySeconds: {{ . }}
      {{- end }}
    {{- end }}
  {{- else if eq $kind "StatefulSet" }}
  serviceName: {{ $name }}
  {{- else if eq ($w.strategy | default "") "RollingUpdate" }}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  {{- else if eq ($w.strategy | default "") "Recreate" }}
  strategy:
    type: Recreate
  {{- else }}
  {{- end }}
  selector:
    matchLabels: { app: {{ $name }} }
  template:
    metadata:
      labels: { app: {{ $name }} }
      {{- if $w.configMaps }}
      annotations:
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
        storageClassName: {{ .storageClass }}
        resources:
          requests:
            storage: {{ .size }}
  {{- end }}
{{- end -}}

{{- define "planpal.service" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- $svc := .svc -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ $svc.name | default $name }}
  labels:
    {{- include "planpal.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $name }}
spec:
  {{- if $svc.headless }}
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
    {{- if and $w.rollout $w.rollout.enabled }}
    apiVersion: argoproj.io/v1alpha1
    kind: Rollout
    {{- else }}
    apiVersion: apps/v1
    kind: {{ $w.kind | default "Deployment" }}
    {{- end }}
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
