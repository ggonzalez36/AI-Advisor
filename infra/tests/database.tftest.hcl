# Unit tests for modules/database: data protection differs by environment.

mock_provider "aws" {
  source = "./tests/mocks"
}
mock_provider "random" {}

variables {
  name              = "test"
  secret_prefix     = "fin-ai-advisor/test"
  subnet_ids        = ["subnet-a", "subnet-b"]
  security_group_id = "sg-rds"
  db_name           = "app"
  db_username       = "admin_user"
  instance_class    = "db.t4g.medium"
  allocated_storage = 50
}

run "prod_protects_data" {
  command = apply

  module {
    source = "./modules/database"
  }

  variables {
    is_prod = true
  }

  assert {
    condition     = aws_db_instance.postgres.multi_az && aws_db_instance.postgres.deletion_protection && !aws_db_instance.postgres.skip_final_snapshot
    error_message = "prod needs Multi-AZ, deletion protection and a final snapshot."
  }

  assert {
    condition     = aws_secretsmanager_secret.db_credentials.recovery_window_in_days == 30
    error_message = "prod secrets need a recovery window."
  }
}

run "always_encrypted_and_private" {
  command = apply

  module {
    source = "./modules/database"
  }

  variables {
    is_prod = false
  }

  assert {
    condition     = aws_db_instance.postgres.storage_encrypted
    error_message = "Storage must always be encrypted at rest."
  }

  assert {
    condition     = !aws_db_instance.postgres.publicly_accessible
    error_message = "The database must never be publicly accessible."
  }

  assert {
    condition     = aws_db_instance.postgres.backup_retention_period >= 7
    error_message = "Backups must be kept at least a week."
  }
}

run "rejects_short_backup_retention" {
  command = plan

  module {
    source = "./modules/database"
  }

  variables {
    is_prod               = false
    backup_retention_days = 1
  }

  expect_failures = [var.backup_retention_days]
}
