# PlanPal — Helm chart

Helm chart for PlanPal on Amazon EKS (`CH4-G3-NAR`, `ap-southeast-3`).

```bash
helm install planpal . -n planpal --create-namespace -f values-prod.yaml
```

## Layout

```
Chart.yaml         chart metadata
values.yaml        defaults, safe for a scratch cluster
values-prod.yaml   overrides for CH4-G3-NAR
templates/         the chart itself
raw-manifests/     the original kubectl manifests this chart was built from
aws/               IAM policy documents, for reference
```

`raw-manifests/` and `aws/` are excluded by `.helmignore`, so they are not
packaged and do not affect rendering. They are kept so the translation from
plain manifests to templates stays reviewable.

## Secrets

No secret value is in this chart. `templates/external-secrets.yaml` declares a
SecretStore and four ExternalSecrets naming which keys to pull from AWS Secrets
Manager (`ch4-g3-secret-nar`). The External Secrets Operator does the reading,
authenticated by an EKS Pod Identity association on its own ServiceAccount.

## Notable values

| Key | Why |
|---|---|
| `postgres.enabled: false` in prod | The database is on RDS |
| `image.tag` | Defaults to `.Chart.AppVersion`; prod pins `v1.0.0` |
| `ingress.certificateArn` | ALB terminates TLS with ACM, no k8s Secret |
| `workers.*` | Three workers generated from one loop |

## Checks

```bash
helm lint . -f values-prod.yaml
helm template planpal . -n planpal -f values-prod.yaml
```
