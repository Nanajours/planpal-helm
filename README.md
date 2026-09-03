# PlanPal — Helm chart

Helm chart for PlanPal on Amazon EKS (`CH4-G3-NAR`, `ap-southeast-3`).

```bash
helm install planpal . -n planpal --create-namespace -f values-prod.yaml
helm test planpal -n planpal
```

## Layout

```
Chart.yaml          chart metadata
values.yaml         defaults, safe for a scratch cluster
values-prod.yaml    overrides for CH4-G3-NAR
values.schema.json  validates values before anything renders
templates/          the chart itself
raw-manifests/      the original kubectl manifests this chart was built from
aws/                IAM policy documents, for reference
```

`raw-manifests/` and `aws/` are excluded by `.helmignore`, so they are not
packaged and do not affect rendering. They are kept so the translation from
plain manifests to templates stays reviewable.

## How the workloads are generated

Every Deployment, StatefulSet, Service, HPA and PodDisruptionBudget comes from
one place: `.Values.workloads`, rendered by `templates/_workload.tpl` through the
loop in `templates/workloads.yaml`. A component is a values entry, not a file:

```yaml
workloads:
  ai-worker:
    enabled: true
    image: ch4-g3-nar/worker
    serviceAccount: planpal
    configMaps: [planpal-config]
    secrets: [planpal-secret]
    command: [planpal-ai-worker]
    probe: { path: /metrics, port: 9093 }
```

Recognised keys are listed above the `workloads` block in `values.yaml`, and
`values.schema.json` rejects anything else — a mistyped `replicaCount` fails at
`helm template`, not at `kubectl apply`.

Probes default to readiness 5s/10s and liveness 15s/20s. Override per workload:

```yaml
    probe:
      exec: [redis-cli, ping]
      readiness: { periodSeconds: 5 }
```

`templates/external-secrets.yaml` uses the same idea: a dict of secret name to
key list, ranged over, instead of four near-identical ExternalSecrets.

## Secrets

No secret value is in this chart. `templates/external-secrets.yaml` declares a
SecretStore and four ExternalSecrets naming which keys to pull from AWS Secrets
Manager (`ch4-g3-secret-nar`). The External Secrets Operator does the reading,
authenticated by an EKS Pod Identity association on its own ServiceAccount.

## Notable values

| Key | Why |
|---|---|
| `workloads.postgres.enabled: false` in prod | The database is on RDS |
| `workloads.<name>.registry: ""` | Pulls from Docker Hub instead of the shared ECR registry |
| `image.tag` | Fallback tag for every workload; defaults to `.Chart.AppVersion` |
| `workloads.<name>.tag` | Per-workload tag, overrides `image.tag`; prod pins each one |
| `workloads.<name>.strategy` | `RollingUpdate` for the two traffic-serving Deployments; unset elsewhere leaves the Kubernetes default |
| `ingress.enabled: false` by default | A scratch cluster has no AWS Load Balancer Controller; prod enables it |
| `ingress.certificateArn` | ALB terminates TLS with ACM, no k8s Secret. `required` when the class is `alb` |

## Checks

```bash
helm lint . -f values-prod.yaml
helm template planpal . -n planpal -f values-prod.yaml
helm test planpal -n planpal          # curls /api/v1/health through the Service
```

## Upgrading once Argo Rollouts is enabled

Helm 4 applies server-side, so it records field ownership. The rollouts
controller legitimately owns two things the chart also declares:

- `.spec.selector` on the `server` and `server-preview` Services, which it
  rewrites on every promotion to point at the live ReplicaSet
- `.spec.template.spec.containers[].image`, if anyone ran
  `kubectl argo rollouts set image`

A plain `helm upgrade` therefore fails with `Apply failed with 1 conflict`.
Pass `--force-conflicts` to let Helm reclaim those fields:

```bash
helm upgrade planpal . -n planpal -f values-prod.yaml --force-conflicts
```

This is safe and it is the point: the chart is the source of truth, so an
imperative `set image` should be reverted by the next upgrade. The controller
re-adds its pod-template-hash to the selectors immediately afterwards.

Use `set image` to demonstrate the rollout mechanism, not to deploy. To change
version for real, set the tag for the workloads you rebuilt and upgrade:

```
./hack/set-tag.sh values-prod.yaml <tag> server schedule-worker notification-worker ai-worker
./hack/set-tag.sh values-prod.yaml <tag> frontend
```

Backend and frontend carry separate tags on purpose: their pipelines run
independently, so a single shared `image.tag` would let whichever finished last
point all three images at a SHA only one of them was ever built with.
