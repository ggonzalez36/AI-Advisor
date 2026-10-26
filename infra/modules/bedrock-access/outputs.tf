output "endpoint_id" {
  description = "ID of the Bedrock runtime interface endpoint"
  value       = aws_vpc_endpoint.bedrock_runtime.id
}

output "endpoint_security_group_id" {
  description = "Security group of the endpoint"
  value       = aws_security_group.endpoint.id
}
