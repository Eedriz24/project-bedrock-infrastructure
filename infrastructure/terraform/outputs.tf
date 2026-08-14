# Only these five non-sensitive outputs belong at the root.
# NEVER add DB passwords, IAM secrets, or access keys here -
# `terraform output -json` prints sensitive values in full.

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.aws_region
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "assets_bucket_name" {
  value = module.s3_lambda.assets_bucket_name
}
