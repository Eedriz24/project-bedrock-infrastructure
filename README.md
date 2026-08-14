# Project Bedrock - InnovateMart Capstone

Two clearly separated layers, matching their different lifecycles,
tooling, and CI/CD triggers:

```
project-bedrock/
├── infrastructure/     # Terraform: VPC, EKS, RDS, DynamoDB, IAM, S3, Lambda resource, Budget, CI/CD
└── application/        # Kubernetes/Helm workload + Lambda source: what runs on/via the platform
```

| | `infrastructure/` | `application/` |
|---|---|---|
| Tool | Terraform | kubectl / Helm |
| Changes | Rare (networking, cluster, DBs) | Frequent (app releases) |
| CI/CD trigger | `infrastructure/terraform/**` -> plan on PR, apply on merge | `application/**` -> validate on PR, deploy on merge |
| State | Remote S3 backend | N/A (Kubernetes API is the source of truth) |
| Owns | AWS resources | `retail-app` namespace workloads, Ingress, NetworkPolicies |

See each folder's own `README.md` for full details, and
`Project-Bedrock-Solution.md` for the complete design writeup and
rubric mapping.

## CI/CD setup

The four workflows already live at the repo root in `.github/workflows/`
— GitHub Actions only reads from that exact path, not nested folders,
so this is already done for you in this zip:

```
.github/workflows/
├── terraform-plan.yml     # infra: PR -> terraform plan, posted as PR comment
├── terraform-apply.yml    # infra: merge to main -> terraform apply
├── app-validate.yml       # app: PR -> lint manifests/Helm/Lambda
└── app-deploy.yml         # app: merge to main -> deploy to EKS
```

Copies of the same files also live under `infrastructure/.github/workflows/`
and `application/.github/workflows/` purely so each layer's workflows are
easy to find alongside the code they govern — but those nested copies are
**not** read by GitHub; only `.github/workflows/` at the repo root runs.
If you edit a workflow, edit it in the root copy (or edit both, they
should stay in sync).

Each workflow is path-scoped (`infrastructure/terraform/**` or
`application/**`), so having all four together is safe — each still only
triggers on changes to its own layer:

| Workflow | Trigger | Does |
|---|---|---|
| `terraform-plan.yml` | PR touching `infrastructure/terraform/**` | Posts `terraform plan` as a sticky PR comment |
| `terraform-apply.yml` | Push to `main` touching `infrastructure/terraform/**` | `terraform apply`, updates `grading.json` |
| `app-validate.yml` | PR touching `application/**` | Lints manifests/Helm/Lambda |
| `app-deploy.yml` | Push to `main` touching `application/**` | Deploys to EKS via Helm or kubectl |

One manual step remains before the infra workflows can authenticate:
see "One-time setup: OIDC bootstrap" in `infrastructure/README.md`.

## Deploy order

```bash
# 1. Infrastructure
cd infrastructure/terraform
cp terraform.tfvars.example terraform.tfvars
terraform init && terraform apply

# 2. Application (pick kubernetes/ or helm/)
cd ../../application/kubernetes
aws eks update-kubeconfig --name project-bedrock-cluster --region us-east-1
kubectl apply -f namespace.yaml -f retail-store/ -f ingress.yaml -f network-policies/
```

## Teardown

Reverse order — remove application workloads first (so the ALB/target
groups aren't orphaned), then destroy infrastructure:

```bash
kubectl delete -f application/kubernetes/ingress.yaml
kubectl delete namespace retail-app
cd infrastructure/terraform && terraform destroy
```

Full manual clean-up steps are in `Project-Bedrock-Solution.md`.
