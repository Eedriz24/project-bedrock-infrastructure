# Infrastructure - Project Bedrock

Everything needed to provision AWS infrastructure: networking, EKS
cluster, managed databases, IAM/access control, the S3+Lambda
serverless resources, budget guardrail, and the CI/CD pipeline that
automates all of it.

**This layer owns:** VPC, EKS control plane + node group, RDS
(MySQL/PostgreSQL), DynamoDB table, `bedrock-dev-view` IAM user + EKS
Access Entry, S3 assets bucket, the Lambda function *resource* (deployed
from code in `../application/lambda`), and the AWS Budget.

**This layer does NOT own:** anything running inside Kubernetes (the
retail-store app, Ingress, NetworkPolicies) - that's in `../application`.

## Contents

```
infrastructure/
├── terraform/              # all Terraform IaC (see terraform/README.md)
└── .github/workflows/      # terraform-plan.yml, terraform-apply.yml
```

## Deploy

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in real values
terraform init
terraform plan
terraform apply
```

## CI/CD Pipeline

| Workflow | Trigger | Does |
|---|---|---|
| `terraform-plan.yml` | Pull Request touching `infrastructure/terraform/**` | `terraform plan`, posted as a **sticky PR comment** (updates in place on new pushes rather than spamming duplicates) |
| `terraform-apply.yml` | Push to `main` touching `infrastructure/terraform/**` | `terraform apply -auto-approve`, then regenerates and commits `grading.json` from the (non-sensitive) root outputs |

### One-time setup: OIDC bootstrap

The pipeline authenticates to AWS via OIDC (no long-lived keys). Because
the workflow needs an IAM role ARN *before* it can run, that role is
created once, manually, using the small standalone config in
`terraform/bootstrap/` (separate state, applied by a human with existing
AWS credentials - not by the pipeline itself):

```bash
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars   # set github_org / github_repo
terraform init
terraform apply
terraform output deploy_role_arn
```

Copy the printed ARN into your GitHub repo secret:

- **Settings -> Secrets and variables -> Actions -> New repository secret**
  `AWS_OIDC_ROLE_ARN` = `<the ARN from above>`

The bootstrap's trust policy restricts *which* GitHub events may assume
the role to this specific repo's pull requests and pushes to `main` -
not a blanket trust of all of GitHub Actions.

### Fallback: Access Keys

Only use this if OIDC federation can't be set up in time. Set the repo
**variable** `AWS_AUTH_METHOD` to `access_keys` (Settings -> Secrets and
variables -> Actions -> Variables), then add:

- `AWS_ACCESS_KEY_ID` (secret)
- `AWS_SECRET_ACCESS_KEY` (secret)

for an IAM user with equivalent permissions to the bootstrap role.
Rotate/deactivate these once grading is complete.

### Blast-radius control during development

`terraform apply` on merge makes real changes. While iterating on a
subset of the infrastructure:

- Scope a manual apply to one module: `terraform apply -target=module.vpc`
- Or use a Terraform workspace per developer/feature:
  `terraform workspace new dev-yourname` before `plan`/`apply`, so
  experiments don't collide with the shared `default` workspace state
  the pipeline uses.

Always read the PR's plan comment in full before merging - the apply
step runs automatically and unattended.

### Secrets hygiene (enforced)

- `outputs.tf` at the Terraform root exposes **only** the five required,
  non-sensitive values (`cluster_endpoint`, `cluster_name`, `region`,
  `vpc_id`, `assets_bucket_name`). DB passwords and the dev IAM user's
  access keys are declared `sensitive = true` at the *module* level and
  never re-exported at the root - because `terraform output -json`
  (used to produce `grading.json`) prints sensitive values in full
  regardless of the `sensitive` flag, which only redacts interactive
  CLI output.
- Real credentials (DB passwords, dev-user access keys) live in AWS
  Secrets Manager / are fetched via `terraform output -raw` locally when
  needed for the deliverable doc - never committed to git or echoed in
  workflow logs.


## Outputs consumed by the application layer

After `terraform apply`, the application layer needs:

- `cluster_name` / `cluster_endpoint` - to `aws eks update-kubeconfig`
- `assets_bucket_name` - referenced nowhere in the app, informational only
- The Secrets Manager ARNs (`bedrock/catalog-mysql`, `bedrock/orders-postgres`)
  and the DynamoDB table name (`bedrock-carts`) - consumed by the
  `SecretProviderClass` / Helm values in `../application`

## Teardown

```bash
cd terraform
terraform destroy
```

Then the manual clean-up (S3 objects, retained log groups, IAM key
rotation) documented in the root solution doc.
