# Consumed by smoke-test.sh to verify the created resources through the AWS API

output "vpc_id" {
  value = module.network.vpc_id
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

output "database_subnet_ids" {
  value = module.network.database_subnet_ids
}

output "nat_gateway_ids" {
  value = module.network.nat_gateway_ids
}

output "alb_security_group_id" {
  value = module.security.alb_security_group_id
}

output "ecs_security_group_id" {
  value = module.security.ecs_security_group_id
}

output "rds_security_group_id" {
  value = module.security.rds_security_group_id
}

output "ai_service_secret_name" {
  value = module.app_secrets.ai_service_secret_name
}

output "state_bucket_name" {
  value = module.state_backend.bucket_name
}

output "lock_table_name" {
  value = module.state_backend.lock_table_name
}
