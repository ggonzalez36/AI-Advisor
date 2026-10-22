#!/usr/bin/env bash
# End-to-end infrastructure test against LocalStack (or any AWS emulator on AWS_ENDPOINT_URL):
# apply -> verify through the AWS API -> drift check -> destroy. Used by CI and locally.
#
#   docker compose -f infra/localstack/docker-compose.yml up -d --wait
#   ./infra/localstack/run.sh
set -euo pipefail

cd "$(dirname "$0")"
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
workdir="$(mktemp -d)"

cleanup() {
  echo "==> terraform destroy"
  terraform destroy -auto-approve -input=false -var "endpoint=${AWS_ENDPOINT_URL}" >/dev/null
  rm -rf "${workdir}"
}

echo "==> terraform init"
terraform init -input=false >/dev/null

trap cleanup EXIT
echo "==> terraform apply"
terraform apply -auto-approve -input=false -var "endpoint=${AWS_ENDPOINT_URL}"

echo "==> second plan (drift check)"
terraform output -json >"${workdir}/outputs.json"
terraform plan -out="${workdir}/tfplan" -input=false -var "endpoint=${AWS_ENDPOINT_URL}" >/dev/null
terraform show -json "${workdir}/tfplan" >"${workdir}/plan.json"

echo "==> smoke tests"
uv run --no-project --with boto3 python smoke_test.py "${workdir}/outputs.json" --plan "${workdir}/plan.json"
