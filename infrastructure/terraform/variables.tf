variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "student_id" {
  description = "Unique suffix for the assets bucket"
  type        = string
  default     = "alt-soe-tin-025-0228"
}

variable "alert_email" {
  description = "Email address for AWS Budget alerts"
  type        = string
  default     = "opeyemi.morakinyo558@gmail.com"
}

variable "eks_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.34"

}

variable "lambda_source_dir" {
  description = "Path (relative to terraform/modules/s3-lambda) to the Lambda function source. Only override if your application/ checkout isn't a sibling of infrastructure/."
  type        = string
  default     = "../../../../application/lambda/bedrock_asset_processor"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability zones to deploy across"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS nodes"
  type        = list(string)
  default     = ["t3.small"]
}

variable "backup_retention_period" {
  description = "Number of days to retain backups for RDS instances"
  type        = number
  default     = 0
}

variable "cluster_admin_principal_arns" {
  description = "IAM principal ARNs to grant explicit cluster-admin EKS Access Entries."
  type        = list(string)
  default     = ["arn:aws:iam::232428703462:user/cicd_user",
    "arn:aws:iam::232428703462:role/bedrock-github-actions-deploy",]
}

variable "retail_app_namespace" {
  description = "Kubernetes namespace the retail-store-sample-app deploys into. Used to scope the Secrets Store CSI Driver's IRSA trust policy."
  type        = string
  default     = "retail-app"
}

