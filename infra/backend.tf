# Remote state in S3 with native locking. Configuration is supplied at init time so no
# account-specific values live in the repo:
#
#   cp backend.hcl.example backend.hcl   # fill in your bucket
#   terraform init -backend-config=backend.hcl
#
# CI validates with `terraform init -backend=false`, which skips this block.
terraform {
  backend "s3" {}
}
