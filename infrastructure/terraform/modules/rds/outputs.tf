output "mysql_secret_arn" {
  value = aws_secretsmanager_secret.mysql.arn
}

output "postgres_secret_arn" {
  value = aws_secretsmanager_secret.postgres.arn
}
