resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# --- IAM: node group role (least privilege) ---
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}
resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}
resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# --- EKS Cluster ---
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.eks_version

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  enabled_cluster_log_types = [
    "api", "audit", "authenticator", "controllerManager", "scheduler"
  ]

  access_config {
    authentication_mode = "API"
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# --- OIDC provider for IRSA ---
data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}

# --- Managed Node Group ---
resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-ng-default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = var.node_instance_type

  scaling_config {
    desired_size = 4
    min_size     = 4
    max_size     = 5
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}


# --- IRSA role for the CloudWatch Observability add-on ---
# Without this, the add-on's agent/Fluent Bit pods have no permission to
# push logs/metrics to CloudWatch and crash-loop on auth errors - which
# surfaces as the add-on staying stuck in DEGRADED until Terraform's
# creation-wait times out. service_account_role_arn tells the add-on to
# provision its ServiceAccounts with this role annotated (EKS Pod
# Identity webhook / IRSA), instead of falling back to node IAM
# permissions (which we deliberately keep minimal per least-privilege).
data "aws_iam_policy_document" "cw_observability_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cw_observability" {
  name               = "${var.cluster_name}-cw-observability-role"
  assume_role_policy = data.aws_iam_policy_document.cw_observability_trust.json
}

resource "aws_iam_role_policy_attachment" "cw_observability" {
  role       = aws_iam_role.cw_observability.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# --- CloudWatch Observability add-on (container logs) ---
# Explicitly depends on the node group: the add-on's pods need running
# nodes to schedule onto, otherwise it degrades/times out waiting for
# a DaemonSet rollout that has nowhere to run.
resource "aws_eks_addon" "cw_observability" {
  cluster_name            = aws_eks_cluster.this.name
  addon_name              = "amazon-cloudwatch-observability"
  service_account_role_arn = aws_iam_role.cw_observability.arn

  depends_on = [
    aws_eks_node_group.default,
    aws_iam_role_policy_attachment.cw_observability,
  ]
}


# --- Explicit cluster-admin Access Entries ---
# Belt-and-suspenders alongside EKS's implicit "cluster creator gets
# admin" bootstrap, which doesn't reliably apply in every apply
# scenario (e.g. applying via an assumed role vs. an IAM user, or if
# the cluster was created in an earlier apply by a different
# principal). Anyone listed here can run kubectl against this cluster
# with full admin rights - keep this list to trusted operators only.
resource "aws_eks_access_entry" "admins" {
  for_each      = toset(var.cluster_admin_principal_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admins" {
  for_each      = toset(var.cluster_admin_principal_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admins]
}


