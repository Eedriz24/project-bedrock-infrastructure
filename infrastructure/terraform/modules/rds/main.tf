resource "aws_db_subnet_group" "this" {
  name       = "bedrock-db-subnet-group"
  subnet_ids = var.private_subnet_ids
}

# ---------------- MySQL (Catalog) ----------------
resource "random_password" "mysql" {
  length  = 20
  special = false
}

resource "aws_security_group" "mysql" {
  name        = "bedrock-mysql-sg"
  description = "Allow MySQL from EKS nodes only"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [var.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "mysql" {
  identifier                 = "bedrock-catalog-mysql"
  engine                     = "mysql"
  engine_version             = "8.0"
  instance_class             = "db.t4g.micro"
  allocated_storage          = 20
  db_name                    = "catalog"
  username                   = "catalog_admin"
  password                   = random_password.mysql.result
  db_subnet_group_name       = aws_db_subnet_group.this.name
  vpc_security_group_ids     = [aws_security_group.mysql.id]
  publicly_accessible        = false
  backup_retention_period    = var.backup_retention_period
  skip_final_snapshot        = true
}

resource "aws_secretsmanager_secret" "mysql" {
  name                    = "bedrock/catalog-mysql"
  recovery_window_in_days = 0 # allow immediate recreation after destroy - avoids "scheduled for deletion" conflicts
}

resource "aws_secretsmanager_secret_version" "mysql" {
  secret_id = aws_secretsmanager_secret.mysql.id
  secret_string = jsonencode({
    username = aws_db_instance.mysql.username
    password = random_password.mysql.result
    host     = aws_db_instance.mysql.address
    port     = 3306
    dbname   = "catalog"
  })
}

# ---------------- PostgreSQL (Orders) ----------------
resource "random_password" "postgres" {
  length  = 20
  special = false
}

resource "aws_security_group" "postgres" {
  name        = "bedrock-postgres-sg"
  description = "Allow PostgreSQL from EKS nodes only"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "postgres" {
  identifier                 = "bedrock-orders-postgres"
  engine                     = "postgres"
  engine_version             = "16"
  instance_class             = "db.t3.micro"
  allocated_storage          = 20
  db_name                    = "orders"
  username                   = "orders_admin"
  password                   = random_password.postgres.result
  db_subnet_group_name       = aws_db_subnet_group.this.name
  vpc_security_group_ids     = [aws_security_group.postgres.id]
  publicly_accessible        = false
  backup_retention_period    = var.backup_retention_period
  skip_final_snapshot        = true
}

resource "aws_secretsmanager_secret" "postgres" {
  name                    = "bedrock/orders-postgres"
  recovery_window_in_days = 0 # allow immediate recreation after destroy - avoids "scheduled for deletion" conflicts
}

resource "aws_secretsmanager_secret_version" "postgres" {
  secret_id = aws_secretsmanager_secret.postgres.id
  secret_string = jsonencode({
    username = aws_db_instance.postgres.username
    password = random_password.postgres.result
    host     = aws_db_instance.postgres.address
    port     = 5432
    dbname   = "orders"
  })
}
