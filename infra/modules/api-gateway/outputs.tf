output "api_endpoint" {
  description = "Public HTTPS endpoint of the API"
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "reviewer_user_pool_id" {
  description = "Cognito user pool where reviewers are provisioned"
  value       = aws_cognito_user_pool.reviewers.id
}

output "reviewer_app_client_id" {
  description = "App client the review UI uses to sign reviewers in"
  value       = aws_cognito_user_pool_client.reviewer_app.id
}

output "vpc_link_security_group_id" {
  description = "Security group of the VPC Link"
  value       = aws_security_group.vpc_link.id
}
