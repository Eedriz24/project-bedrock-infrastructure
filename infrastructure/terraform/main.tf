module "vpc" {
  source   = "./modules/vpc"
  vpc_cidr = var.vpc_cidr
  azs      = var.azs
}


module "eks" {
  source                       = "./modules/eks"
  cluster_name                 = "project-bedrock-cluster"
  eks_version                  = var.eks_version
  vpc_id                       = module.vpc.vpc_id
  node_instance_types          = var.node_instance_types #unresolved variable
  private_subnet_ids           = module.vpc.private_subnet_ids
  public_subnet_ids            = module.vpc.public_subnet_ids
  cluster_admin_principal_arns = var.cluster_admin_principal_arns
}

module "rds" {
  source                  = "./modules/rds"
  vpc_id                  = module.vpc.vpc_id
  private_subnet_ids      = module.vpc.private_subnet_ids
  node_security_group_id  = module.eks.node_security_group_id
  backup_retention_period = var.backup_retention_period
}

module "dynamodb" {
  source = "./modules/dynamodb"
}

module "s3_lambda" {
  source            = "./modules/s3-lambda"
  student_id        = var.student_id
  lambda_source_dir = var.lambda_source_dir
}

module "iam_dev_user" {
  source            = "./modules/iam-dev-user"
  cluster_name      = module.eks.cluster_name
  assets_bucket_arn = module.s3_lambda.assets_bucket_arn
}

module "budget" {
  source      = "./modules/budget"
  alert_email = var.alert_email
}


