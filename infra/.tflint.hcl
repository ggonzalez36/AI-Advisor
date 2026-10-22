# TFLint: catches what `terraform validate` cannot (invalid instance types, deprecated syntax,
# unused declarations, missing descriptions). Run from infra/: tflint --init && tflint --recursive

config {
  call_module_type = "local" # Lint the module calls too, with the values the root passes in
}

plugin "terraform" {
  enabled = true
  preset  = "all"
}

plugin "aws" {
  enabled = true
  version = "0.49.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Outputs of the LocalStack root are read by a script, not people: descriptions add nothing
rule "terraform_documented_outputs" {
  enabled = false
}
