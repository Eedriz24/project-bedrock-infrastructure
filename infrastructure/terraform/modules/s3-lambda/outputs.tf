output "assets_bucket_name" {
  value = aws_s3_bucket.assets.bucket
}

output "assets_bucket_arn" {
  value = aws_s3_bucket.assets.arn
}

output "lambda_function_name" {
  value = aws_lambda_function.processor.function_name
}
