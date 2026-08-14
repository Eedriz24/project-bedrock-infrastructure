# Project Bedrock — InnovateMart EKS Capstone Solution

**Region:** us-east-1 | **Cluster:** project-bedrock-cluster | **Namespace:** retail-app
**Tag applied to all resources:** `Project: tinyuka-2025-capstone`

This document is the complete technical design and implementation guide for Project Bedrock: a production-grade EKS platform running the AWS Retail Store Sample App, with managed data services, secure developer access, observability, a serverless image-processing extension, and CI/CD automation.

---

## 1. Architecture Overview

```
                         ┌───────────────────────────────────────────────────────────┐
                         │                    VPC: project-bedrock-vpc (10.0.0.0/16)   │
                         │                                                             │
   Internet ── ALB ──────┼──► Public Subnets (AZ-a, AZ-b)  ── Single NAT Gateway ─────┼──► Private Subnets (AZ-a, AZ-b)
                         │        (Ingress: ALB, NAT)                                  │        EKS Worker Nodes (EC2/Fargate)
                         │                                                             │        RDS MySQL (catalog)
                         │                                                             │        RDS PostgreSQL (orders)
                         │                                                             │        In-cluster: RabbitMQ, Redis
                         └───────────────────────────────────────────────────────────┘
   DynamoDB (carts) — regional managed service, accessed via IRSA from pods
   S3 (bedrock-assets-<id>) ──Event Notification──► Lambda (bedrock-asset-processor) ──► CloudWatch Logs
   EKS Control Plane Logs (API/Audit/Authenticator/ControllerManager/Scheduler) ──► CloudWatch Log Groups
   CloudWatch Observability Add-on (Fluent Bit/CloudWatch agent) ──► Container Logs
   IAM: bedrock-dev-view (ReadOnlyAccess + s3:PutObject on assets bucket) + EKS Access Entry (AmazonEKSViewPolicy, retail-app ns)
```

A PNG/draw.io version of this diagram (VPC/subnets, EKS, data layer, ALB, S3→Lambda flow) should be exported and linked in the final deliverable doc — see Section 9.

---

## 2. Repository Structure

```
project-bedrock/
├── terraform/
│   ├── backend.tf
│   ├── providers.tf
│   ├── variables.tf
│   ├── outputs.tf              # only the 5 required non-sensitive outputs
│   ├── main.tf
│   ├── modules/
│   │   ├── vpc/
│   │   ├── eks/
│   │   ├── rds/
│   │   ├── dynamodb/
│   │   ├── iam-dev-user/
│   │   ├── s3-lambda/
│   │   └── budget/
├── kubernetes/
│   ├── namespace.yaml
│   ├── retail-store/            # manifests or kustomize overlay
│   ├── ingress.yaml
│   └── network-policies/        # bonus 5.4
├── helm/                        # bonus 5.1
│   └── retail-store/values-rds-dynamodb.yaml
├── lambda/
│   └── bedrock_asset_processor/
│       └── handler.py
├── .github/workflows/
│   ├── terraform-plan.yml
│   └── terraform-apply.yml
├── grading.json
└── README.md
```

---

## 3. Infrastructure as Code (Terraform)

### 3.1 Remote State Backend

Terraform ≥1.11 supports native S3 locking, removing the need for a DynamoDB lock table.

```hcl
# backend.tf
terraform {
  backend "s3" {
    bucket       = "bedrock-tfstate-<student-id>"
    key          = "project-bedrock/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true      # native S3 locking (TF 1.11+)
    encrypt      = true
  }
  required_version = ">= 1.11.0"
}
```

The state bucket itself is created once, out-of-band (or via a small bootstrap `terraform apply` with local state), with versioning and default SSE-KMS/AES256 encryption enabled, and Block Public Access on.

### 3.2 Provider & Default Tags

```hcl
# providers.tf
provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Project = "tinyuka-2025-capstone"
    }
  }
}
```

Using `default_tags` ensures every resource created by the AWS provider is tagged automatically — satisfying the 5% "Standards" rubric line without repetitive per-resource tag blocks.

### 3.3 VPC Module

- CIDR `10.0.0.0/16`, 2 public + 2 private subnets across `us-east-1a` / `us-east-1b`.
- **Single NAT Gateway** (in one public subnet) shared by both private subnets — cost guardrail per spec.
- Public subnets tagged `kubernetes.io/role/elb = 1`; private subnets tagged `kubernetes.io/role/internal-elb = 1` and `kubernetes.io/cluster/project-bedrock-cluster = shared` for the AWS Load Balancer Controller and EKS to auto-discover them.
- VPC Name tag: `project-bedrock-vpc` (as required).

Use the community `terraform-aws-modules/vpc/aws` module pinned to a recent version, or hand-roll — either satisfies grading as long as the name tag and topology match.

### 3.4 EKS Cluster Module

- Cluster name: `project-bedrock-cluster`.
- **Kubernetes version:** at plan time, check the [EKS version lifecycle table](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html) and pin to the **oldest version that is not yet end-of-standard-support**. Do not hardcode a version in this document — verify against the live AWS table immediately before `terraform apply`, since EKS deprecates versions on a rolling schedule. Set it as a Terraform variable (`eks_version`) so it's a single point of update.
- Managed Node Group: 2× `t3.medium` (or `m6g` for Graviton cost savings), min 2 / desired 2 / max 4, placed in private subnets only (no public IPs on nodes).
- **IAM (least privilege):**
  - Cluster role: `AmazonEKSClusterPolicy` only.
  - Node role: `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly` — nothing broader.
  - Enable **IRSA** (IAM Roles for Service Accounts) via an OIDC provider on the cluster, so workloads (ALB controller, CloudWatch agent, app pods needing DynamoDB access) get scoped IAM roles instead of node-wide permissions.
- **Control plane logging** — enable all five log types:

```hcl
resource "aws_eks_cluster" "this" {
  name     = "project-bedrock-cluster"
  role_arn = aws_iam_role.cluster.arn
  version  = var.eks_version

  vpc_config {
    subnet_ids              = concat(module.vpc.private_subnet_ids, module.vpc.public_subnet_ids)
    endpoint_private_access  = true
    endpoint_public_access   = true   # restrict via public_access_cidrs in production
  }

  enabled_cluster_log_types = [
    "api", "audit", "authenticator", "controllerManager", "scheduler"
  ]

  access_config {
    authentication_mode = "API"   # required for EKS Access Entries
  }
}
```

Enabling `enabled_cluster_log_types` automatically ships logs to the `/aws/eks/project-bedrock-cluster/cluster` CloudWatch Log Group.

### 3.5 Cost Guardrails

**AWS Budget:**

```hcl
resource "aws_budgets_budget" "bedrock" {
  name         = "project-bedrock-monthly"
  budget_type  = "COST"
  limit_amount = "20"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$tinyuka-2025-capstone"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
}
```

Single NAT Gateway (already covered in VPC module) is the other guardrail.

### 3.6 Required Root Outputs (exactly five, non-sensitive)

```hcl
# outputs.tf
output "cluster_endpoint"    { value = aws_eks_cluster.this.endpoint }
output "cluster_name"        { value = aws_eks_cluster.this.name }
output "region"               { value = var.aws_region }
output "vpc_id"               { value = module.vpc.vpc_id }
output "assets_bucket_name"   { value = aws_s3_bucket.assets.bucket }
```

No IAM secrets, DB passwords, or connection strings are ever placed in root outputs — `terraform output -json` prints sensitive values in full, so this is enforced by simply never declaring them as outputs in the first place. Generate the grading file with:

```bash
terraform output -json > ../grading.json
```

---

## 4. Data Layer (Managed AWS Services)

| Service | Engine | Placement | Sizing |
|---|---|---|---|
| Catalog DB | RDS MySQL 8.x | Private subnets, single-AZ | `db.t4g.micro` |
| Orders DB | RDS PostgreSQL 16.x | Private subnets, single-AZ | `db.t3.micro` |
| Carts | DynamoDB (on-demand) | Regional, no VPC needed | Pay-per-request |

### 4.1 Security

- Dedicated **DB Subnet Group** using only the two private subnets.
- Dedicated **Security Groups** per RDS instance, ingress restricted to the EKS **node security group** (or a dedicated pod SG if using Security Groups for Pods) on port 3306 / 5432 only — no `0.0.0.0/0`, no public accessibility (`publicly_accessible = false`).
- Credentials generated with `random_password`, stored in **AWS Secrets Manager**:

```hcl
resource "random_password" "mysql" { length = 20; special = true }

resource "aws_secretsmanager_secret" "mysql" {
  name = "bedrock/catalog-mysql"
}
resource "aws_secretsmanager_secret_version" "mysql" {
  secret_id     = aws_secretsmanager_secret.mysql.id
  secret_string = jsonencode({
    username = "catalog_admin"
    password = random_password.mysql.result
    host     = aws_db_instance.mysql.address
    dbname   = "catalog"
  })
}
```

- In-cluster, credentials are injected via the **AWS Secrets Manager and SSM Parameter Store CSI Driver** (Secrets Store CSI Driver), mounted as a volume and exposed to the container as env vars — **never** written into a `values.yaml` committed to git.
- DynamoDB access for the carts pod uses an **IRSA** service account with a policy scoped to `dynamodb:GetItem/PutItem/UpdateItem/DeleteItem/Query` on the specific carts table ARN only.

### 4.2 Backups (Bonus 5.5)

```hcl
backup_retention_period = 7   # days
```
set on both `aws_db_instance` resources, documented as a 7-day retention window balancing recovery flexibility against storage cost.

---

## 5. Application Deployment

1. `kubectl create namespace retail-app` (or via manifest with the `Project` label for consistency).
2. Deploy the [aws-containers/retail-store-sample-app](https://github.com/aws-containers/retail-store-sample-app) either as raw manifests (`kubernetes/retail-store/`) or, for the bonus, as the upstream Helm chart with a custom `values-rds-dynamodb.yaml` that:
   - Disables the in-cluster `mysql` and `postgresql` sub-charts.
   - Points `catalog` and `orders` env vars at the RDS endpoints (via Secrets Store CSI-mounted secrets).
   - Points `carts` at the DynamoDB table name/region.
   - Leaves `rabbitmq` and `redis` sub-charts enabled (in-cluster, per spec).
3. Install the **AWS Load Balancer Controller** (latest stable Helm chart, `eks-charts` repo) into `kube-system`, using an IRSA-scoped IAM role (`elasticloadbalancing:*`, `ec2:Describe*`, etc. — the AWS-published controller policy).
4. Create an `Ingress` for the `ui` service:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ui
  namespace: retail-app
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ui
                port:
                  number: 80
```

5. Verify all pods `Running`/`Ready` in `retail-app`, and the ALB DNS name resolves and serves the storefront.

---

## 6. Secure Developer Access

### 6.1 IAM User

```hcl
resource "aws_iam_user" "dev" {
  name = "bedrock-dev-view"
}

resource "aws_iam_user_policy_attachment" "readonly" {
  user       = aws_iam_user.dev.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# scoped inline policy for the S3 assets bucket only
resource "aws_iam_user_policy" "s3_put" {
  name = "bedrock-dev-s3-put"
  user = aws_iam_user.dev.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = "${aws_s3_bucket.assets.arn}/*"
    }]
  })
}

resource "aws_iam_access_key" "dev" {
  user = aws_iam_user.dev.name
}
```

### 6.2 EKS Access Entry (not aws-auth ConfigMap)

```hcl
resource "aws_eks_access_entry" "dev" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_user.dev.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "dev_view" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_user.dev.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["retail-app"]
  }
}
```

### 6.3 Verification

```bash
aws eks update-kubeconfig --name project-bedrock-cluster --region us-east-1 \
  --profile bedrock-dev-view

kubectl get pods -n retail-app        # ✅ succeeds
kubectl delete pod <ui-pod> -n retail-app   # ❌ Forbidden (view-only)
```

Access key/secret and console password are rotated/deactivated after grading (see Section 9 deliverable checklist).

---

## 7. Observability

- **Control plane logs:** enabled in Section 3.4 (`enabled_cluster_log_types`), visible under `/aws/eks/project-bedrock-cluster/cluster` in CloudWatch.
- **Container/application logs:** install the **Amazon CloudWatch Observability EKS add-on** (`amazon-cloudwatch-observability`), which deploys CloudWatch agent + Fluent Bit as a DaemonSet via IRSA, shipping pod stdout/stderr to `/aws/containerinsights/project-bedrock-cluster/application`.

```hcl
resource "aws_eks_addon" "cw_observability" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "amazon-cloudwatch-observability"
}
```

- Verify: CloudWatch → Log Insights → query the application log group and confirm `ui`, `catalog`, `orders`, `carts` pod logs are present.

---

## 8. Event-Driven Extension (S3 → Lambda)

### 8.1 S3 Bucket

```hcl
resource "aws_s3_bucket" "assets" {
  bucket = "bedrock-assets-${var.student_id}"
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

### 8.2 Lambda (least-privilege execution role)

```python
# lambda/bedrock_asset_processor/handler.py
def handler(event, context):
    for record in event["Records"]:
        key = record["s3"]["object"]["key"]
        print(f"Image received: {key}")
    return {"statusCode": 200}
```

```hcl
resource "aws_iam_role" "lambda_exec" {
  name               = "bedrock-asset-processor-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "lambda_scoped" {
  role = aws_iam_role.lambda_exec.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.assets.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:us-east-1:*:log-group:/aws/lambda/bedrock-asset-processor:*"
      }
    ]
  })
}

resource "aws_lambda_function" "processor" {
  function_name = "bedrock-asset-processor"
  role          = aws_iam_role.lambda_exec.arn
  runtime       = "python3.12"
  handler       = "handler.handler"
  filename      = data.archive_file.lambda_zip.output_path
}

resource "aws_lambda_permission" "s3_invoke" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.assets.arn
}

resource "aws_s3_bucket_notification" "trigger" {
  bucket = aws_s3_bucket.assets.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.processor.arn
    events               = ["s3:ObjectCreated:*"]
  }
  depends_on = [aws_lambda_permission.s3_invoke]
}
```

Verification: upload a test file with the `bedrock-dev-view` credentials (`aws s3 cp test.jpg s3://bedrock-assets-<id>/ --profile bedrock-dev-view`) and confirm `Image received: test.jpg` in the Lambda's CloudWatch log group.

---

## 9. CI/CD Pipeline (GitHub Actions)

**`terraform-plan.yml`** (on pull_request):
```yaml
name: Terraform Plan
on:
  pull_request:
    paths: ["terraform/**"]

permissions:
  id-token: write
  contents: read
  pull-requests: write

jobs:
  plan:
    runs-on: ubuntu-latest
    defaults:
      run: { working-directory: terraform }
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_OIDC_ROLE_ARN }}
          aws-region: us-east-1
      - uses: hashicorp/setup-terraform@v3
      - run: terraform init
      - run: terraform plan -no-color -out=tfplan | tee plan.txt
      - uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const plan = fs.readFileSync('terraform/plan.txt', 'utf8').slice(0, 60000);
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: "```\n" + plan + "\n```"
            });
```

**`terraform-apply.yml`** (on push to `main`): identical setup, replaces `terraform plan` with `terraform apply -auto-approve tfplan` (re-planning first). Uses the same OIDC role — no long-lived AWS keys stored as secrets. An access-key fallback (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` repo secrets) is acceptable only if OIDC federation isn't set up in time.

To limit blast radius while iterating, early-stage PRs can scope applies with `-target=module.vpc` etc.; the final `main` pipeline applies the full root module.

---

## 10. Bonus Objectives — Summary of Approach

| # | Objective | Approach |
|---|---|---|
| 5.1 | Helm | Use upstream `retail-store-sample-app` chart + `values-rds-dynamodb.yaml`; deploy via `helm upgrade --install retail-store ./helm/retail-store -n retail-app -f values-rds-dynamodb.yaml`. Chart committed to repo. |
| 5.2 | TLS/ACM | Register/verify a domain (or `*.nip.io`) in Route 53 / ACM DNS validation; issue an ACM cert; add `alb.ingress.kubernetes.io/certificate-arn` and `listen-ports: '[{"HTTPS":443}]'` annotations to the Ingress; redirect HTTP→HTTPS. |
| 5.3 | Autoscaling | Install Karpenter (IRSA-scoped) with a `NodePool`/`EC2NodeClass` targeting the private subnets; scale UI replicas up (`kubectl scale deploy/ui --replicas=10 -n retail-app`) and document new nodes provisioning in `kubectl get nodes -w`. |
| 5.4 | NetworkPolicy | Default-deny ingress in `retail-app`, then per-service allow rules (e.g., `ui`→`catalog/carts/orders/checkout`; `catalog` denied from reaching `orders`), enforced via the VPC CNI's network policy support (or Calico if not using the AWS CNI's native enforcement). |
| 5.5 | Resilience | `kubectl delete pod <ui-pod>` → observe replacement scheduled within seconds via `kubectl get pods -w`; document timestamps. RDS `backup_retention_period = 7` on both instances (Section 4.2). |

---

## 11. Teardown Guide

```bash
# 1. Remove Kubernetes-managed AWS resources first (ALB, target groups) so Terraform doesn't orphan them
kubectl delete ingress ui -n retail-app
helm uninstall retail-store -n retail-app   # if deployed via Helm
kubectl delete namespace retail-app

# 2. Uninstall cluster add-ons provisioned via Helm/kubectl (LB controller, Karpenter, CloudWatch add-on if not Terraform-managed)
helm uninstall aws-load-balancer-controller -n kube-system

# 3. Destroy Terraform-managed infra
cd terraform
terraform destroy

# 4. Manual clean-up (resources Terraform won't touch)
aws s3 rm s3://bedrock-assets-<student-id> --recursive
aws s3api delete-bucket --bucket bedrock-assets-<student-id>
aws logs delete-log-group --log-group-name /aws/eks/project-bedrock-cluster/cluster
aws logs delete-log-group --log-group-name /aws/containerinsights/project-bedrock-cluster/application
aws logs delete-log-group --log-group-name /aws/lambda/bedrock-asset-processor
aws iam list-access-keys --user-name bedrock-dev-view   # then deactivate/delete
aws iam delete-user --user-name bedrock-dev-view          # after detaching policies

# 5. Remove the remote state bucket (only after confirming nothing else depends on it)
aws s3 rm s3://bedrock-tfstate-<student-id> --recursive
aws s3api delete-bucket --bucket bedrock-tfstate-<student-id>
```

---

## 12. Deliverables Checklist (Section 6 of brief)

- [ ] Google Doc shared (Viewer) with Innocent Chukwuemeka containing all items below.
- [ ] All AWS resources tagged `Project: tinyuka-2025-capstone` (enforced via provider `default_tags`).
- [ ] Public git repo link (Terraform, pipeline YAML, Lambda code, k8s manifests/Helm values).
- [ ] Architecture diagram (PNG export of Section 1 diagram, drawn in draw.io/Lucidchart/`diagrams` lib).
- [ ] Deployment guide: how to trigger the pipeline + live storefront URL.
- [ ] `bedrock-dev-view` Access Key ID/Secret + console password (rotate/deactivate after grading).
- [ ] Teardown guide (Section 11 above).
- [ ] `grading.json` (from `terraform output -json`) committed at repo root — verify it contains **only** the five required non-sensitive outputs.

---

## 13. Rubric Self-Check

| Category | Weight | Where addressed |
|---|---|---|
| Standards | 5% | §3.2 default_tags, naming throughout |
| Infra | 15% | §3 (VPC, EKS, remote state, NAT/budget guardrails) |
| App | 15% | §5 |
| Security | 15% | §6 |
| Observability | 15% | §7 |
| Serverless | 15% | §8 |
| CI/CD | 15% | §9 |
| Diagram | 5% | §1 (export required separately) |
| Bonus | +20 | §10 |
