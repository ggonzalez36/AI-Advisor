output "endpoint" {
  description = "PostgreSQL connection endpoint (host:port)"
  value       = aws_db_instance.postgres.endpoint
}

output "credentials_secret_arn" {
  description = "Secret holding the database connection details"
  value       = aws_secretsmanager_secret.db_credentials.arn
}
