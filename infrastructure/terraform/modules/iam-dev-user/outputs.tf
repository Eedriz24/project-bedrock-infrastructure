# Marked sensitive so they never appear in the CLI plan/apply output.
# These are still NOT to be included as root-module outputs (see terraform/outputs.tf).
output "access_key_id" {
  value     = aws_iam_access_key.dev.id
  sensitive = true
}

output "secret_access_key" {
  value     = aws_iam_access_key.dev.secret
  sensitive = true
}
