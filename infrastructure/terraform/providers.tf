provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project = "tinyuka-2025-capstone"
      owner   = "Eedriz24"
    }
  }
}
