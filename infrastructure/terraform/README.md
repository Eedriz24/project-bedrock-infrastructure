# Terraform - Project Bedrock Infrastructure

Provisions VPC, EKS, RDS (MySQL + PostgreSQL), DynamoDB, the developer IAM
user + EKS Access Entry, the S3 assets bucket + Lambda processor, and the
AWS Budget guardrail.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in real values
terraform init
terraform plan
terraform apply
```

## Outputs

Only five non-sensitive outputs are exposed at the root (see `outputs.tf`).
Generate the grading file with:

```bash
terraform output -json > ../grading.json
```

## Teardown

```bash
terraform destroy
```

Followed by manual clean-up of S3 objects and retained CloudWatch log
groups - see the root repository README for the full sequence.
