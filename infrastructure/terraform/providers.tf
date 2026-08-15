provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project = "tinyuka-2025-capstone"
      Owner   = "Eedriz24"
    }
  }
}

# --- Cluster auth data, used to configure the kubernetes/helm providers ---
# These depend on module.eks, so Terraform correctly sequences cluster
# creation before anything here tries to authenticate to it, all within
# a single `terraform apply`.
data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}