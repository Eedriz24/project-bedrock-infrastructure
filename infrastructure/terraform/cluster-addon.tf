# ============================================================
# AWS Load Balancer Controller
# Required for the app's Ingress -> ALB to work at all.
# ============================================================

# Official IAM policy, fetched live from the project's published source
# rather than hand-copied, so it stays accurate as AWS updates it.
data "http" "alb_controller_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "alb_controller" {
  name   = "bedrock-alb-controller-policy"
  policy = data.http.alb_controller_iam_policy.response_body
}

data "aws_iam_policy_document" "alb_controller_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "bedrock-alb-controller-role"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_trust.json
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.alb_controller.arn
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  depends_on = [
    module.eks,
    aws_iam_role_policy_attachment.alb_controller,
  ]
}

# ============================================================
# Secrets Store CSI Driver + AWS provider
# Required to mount RDS credentials from Secrets Manager into pods
# (catalog-mysql, orders-postgres secrets) without hardcoding them.
# ============================================================

resource "helm_release" "secrets_store_csi_driver" {
  name       = "csi-secrets-store"
  repository = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  version    = "1.4.0"
  chart      = "secrets-store-csi-driver"
  namespace  = "kube-system"

  set {
    name  = "syncSecret.enabled"
    value = "true"
  }

  depends_on = [module.eks]
}

# The AWS provider for the CSI driver ships as a DaemonSet manifest, not
# a Helm chart - applied here via kubectl through a null_resource, since
# that's how AWS officially documents installing it. Guarded so it only
# re-runs when the manifest URL or cluster name changes.
resource "null_resource" "secrets_store_csi_aws_provider" {
  triggers = {
    cluster_name = module.eks.cluster_name
    manifest_url = "https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml"
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}
      kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml
    EOT
  }

  depends_on = [helm_release.secrets_store_csi_driver]
}

# IRSA role granting pods (via the CSI driver) read access to exactly
# the two RDS secrets - not broader Secrets Manager access.
data "aws_iam_policy_document" "secrets_csi_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${replace(module.eks.oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:${var.retail_app_namespace}:*"]
    }
  }
}

resource "aws_iam_role" "secrets_csi" {
  name               = "bedrock-secrets-csi-role"
  assume_role_policy = data.aws_iam_policy_document.secrets_csi_trust.json
}

resource "aws_iam_role_policy" "secrets_csi_read" {
  name = "bedrock-secrets-csi-read"
  role = aws_iam_role.secrets_csi.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = [
        module.rds.mysql_secret_arn,
        module.rds.postgres_secret_arn,
      ]
    }]
  })
}