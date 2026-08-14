output "carts_table_name" {
  value = aws_dynamodb_table.carts.name
}

output "carts_table_arn" {
  value = aws_dynamodb_table.carts.arn
}
