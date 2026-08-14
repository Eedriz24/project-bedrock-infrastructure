variable "vpc_id" {
  type = string
}
variable "private_subnet_ids" {
  type = list(string)
}
variable "node_security_group_id" {
  type = string
}

variable "backup_retention_period" {
  default = 0
}
