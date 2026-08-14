variable "student_id" {
  type = string
  default = "alt-soe—tin-025-0228"
}

variable "lambda_source_dir" {
  description = "Path to the Lambda function source directory. Defaults to the sibling application/ layout (infrastructure/ and application/ under the same repo root). Override if deploying from a standalone infrastructure checkout, e.g. a path where you've copied or cloned the lambda source locally."
  type        = string
  default     = "../../../../application/lambda/bedrock_asset_processor"
}
