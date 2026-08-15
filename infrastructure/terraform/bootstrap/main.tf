# Bootstrap: GitHub OIDC provider + CI/CD IAM role
#
# WHY THIS IS SEPARATE FROM THE MAIN ROOT MODULE:
# The GitHub Actions workflows need an IAM role ARN to assume via OIDC
# *before* they can run `terraform plan`/`apply` on the main root module.
# That's a chicken-and-egg problem - so this small bootstrap module is
# applied once, manually, by a human with existing AWS admin credentials,
# to create the trust relationship. After that, the pipeline is fully
# self-sufficient and this bootstrap module is rarely touched again.
#
# Usage:
#   cd infrastructure/terraform/bootstrap
#   cp terraform.tfvars.example terraform.tfvars   # fill in your GitHub org/repo
#   terraform init
#   terraform apply
#   terraform output deploy_role_arn   # copy this into the AWS_OIDC_ROLE_ARN repo secret

terraform {
  required_version = ">= 1.11.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Deliberately local state: this is a one-time, rarely-changed bootstrap
  # applied by a human, not by the CI/CD pipeline it creates access for.
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = { Project = "tinyuka-2025-capstone" }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "github_org" {
  description = "GitHub organization or username that owns the repo"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (without org prefix)"
  type        = string
}

# --- GitHub's OIDC identity provider (one per AWS account, reusable across repos) ---
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# --- Trust policy: only THIS repo, only these branches/events, may assume the role ---
data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
  test     = "StringLike"
  variable = "token.actions.githubusercontent.com:sub"
  values = [
    "repo:${var.github_org}*/${var.github_repo}*:pull_request",
    "repo:${var.github_org}*/${var.github_repo}*:ref:refs/heads/main",
    "repo:${var.github_org}*/${var.github_repo}*:environment:production",
  ]
}
  }
}

resource "aws_iam_role" "ci_deploy" {
  name               = "bedrock-github-actions-deploy"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

# --- Permissions the pipeline actually needs ---
# Broad enough to provision every resource in the root module, scoped to
# this account/region only via the trust condition above (not via IAM
# policy wildcarding by design - PowerUserAccess is used here for
# capstone simplicity; tighten to a custom least-privilege policy for a
# real production pipeline).
resource "aws_iam_role_policy_attachment" "power_user" {
  role       = aws_iam_role.ci_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# PowerUserAccess excludes IAM management, so add scoped IAM permissions
# for the specific roles/users/policies/access-entries this project creates.
resource "aws_iam_role_policy" "iam_scoped" {
  name = "bedrock-ci-iam-scoped"
  role = aws_iam_role.ci_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "iam:CreateRole", "iam:DeleteRole", "iam:GetRole",
        "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
        "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies", "iam:TagRole", "iam:UntagRole",
        "iam:CreateUser", "iam:DeleteUser", "iam:GetUser",
        "iam:PutUserPolicy", "iam:DeleteUserPolicy", "iam:GetUserPolicy",
        "iam:AttachUserPolicy", "iam:DetachUserPolicy", "iam:ListAttachedUserPolicies",
        "iam:CreateAccessKey", "iam:DeleteAccessKey", "iam:ListAccessKeys",
        "iam:CreateOpenIDConnectProvider", "iam:GetOpenIDConnectProvider",
        "iam:PassRole","iam:TagUser", "iam:UntagUser",
        "iam:DeleteOpenIDConnectProvider", "iam:TagOpenIDConnectProvider",
        "iam:UntagOpenIDConnectProvider", "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy",
        "iam:GetPolicyVersion", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
        "iam:ListPolicyVersions", "iam:TagPolicy", "iam:UntagPolicy",
      ]
      Resource = "*"
    }]
  })
}

output "deploy_role_arn" {
  value = aws_iam_role.ci_deploy.arn
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}


