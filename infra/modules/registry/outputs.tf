output "repository_urls" {
  description = "Repository URL per service"
  value       = { for k, repo in aws_ecr_repository.service : k => repo.repository_url }
}
