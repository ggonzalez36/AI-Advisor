output "bucket_name" {
  description = "State bucket to put in backend.hcl"
  value       = aws_s3_bucket.state.id
}

output "lock_table_name" {
  description = "DynamoDB lock table to put in backend.hcl (Terraform < 1.10)"
  value       = aws_dynamodb_table.lock.name
}

output "kms_key_arn" {
  description = "KMS key that encrypts the state"
  value       = aws_kms_key.state.arn
}
