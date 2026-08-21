variable "cluster_name" {
  type = string
  default = "project-bedrock-cluster"
}
variable "eks_version" {
  type = string
  
}
variable "vpc_id" {
  type = string
}
variable "private_subnet_ids" {
  type = list(string)
}
variable "public_subnet_ids" {
  type = list(string)
}

variable "node_instance_type" {
  description = "Instance types for the default EKS managed node group."
  type        = list(string)
  default     = ["t3.small"]
}
# --- IAM: cluster role (least privilege) ---
// Variable for cluster admin ARNs referenced by aws_eks_access_entry/resources
variable "cluster_admin_principal_arns" {
  description = "List of IAM principal ARNs to grant cluster-admin access via aws_eks_access_entry/aws_eks_access_policy_association"
  type        = list(string)
  default     = []
}