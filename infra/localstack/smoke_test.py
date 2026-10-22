"""Verify the LocalStack environment through the AWS API, independently of Terraform.

Terraform reporting "Apply complete" only proves it sent the calls. These checks read the
resources back and assert the security properties the design depends on.

Usage:
    terraform -chdir=infra/localstack output -json > outputs.json
    terraform -chdir=infra/localstack plan -out=tfplan && \
        terraform -chdir=infra/localstack show -json tfplan > plan.json
    uv run --with boto3 python infra/localstack/smoke_test.py outputs.json --plan plan.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections.abc import Callable

import boto3

ENDPOINT = os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")
REGION = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")

# Known emulator quirks, not configuration changes. On rules that reference another security
# group, moto (and LocalStack's EC2, built on it) reads the group back as "<account>/sg-..."
# and drops the description. Each quirk is a predicate on (before, after); anything else,
# including a real description change, fails the drift check.
SG_RULE_QUIRKS = {
    "referenced_security_group_id": lambda before, after: strip_account(before) == strip_account(after),
    "description": lambda before, after: not before,
}
EMULATOR_QUIRKS = {
    "aws_vpc_security_group_ingress_rule": SG_RULE_QUIRKS,
    "aws_vpc_security_group_egress_rule": SG_RULE_QUIRKS,
}


def client(service: str):
    return boto3.client(
        service,
        endpoint_url=ENDPOINT,
        region_name=REGION,
        aws_access_key_id="test",
        aws_secret_access_key="test",
    )


def strip_account(group_id: str | None) -> str | None:
    return group_id.split("/")[-1] if group_id else group_id


def sg_rules(ec2, group_id: str) -> list[dict]:
    rules = ec2.describe_security_group_rules(Filters=[{"Name": "group-id", "Values": [group_id]}])
    return rules["SecurityGroupRules"]


# ------------------------------------------------------------------------------
# Checks: each returns None on success and raises AssertionError with a reason otherwise
# ------------------------------------------------------------------------------


def check_vpc(out: dict) -> None:
    ec2 = client("ec2")
    vpc = ec2.describe_vpcs(VpcIds=[out["vpc_id"]])["Vpcs"][0]
    assert vpc["CidrBlock"] == "10.0.0.0/16", f"unexpected VPC CIDR {vpc['CidrBlock']}"
    dns = ec2.describe_vpc_attribute(VpcId=out["vpc_id"], Attribute="enableDnsHostnames")
    assert dns["EnableDnsHostnames"]["Value"], "DNS hostnames must be enabled (Cloud Map, RDS endpoints)"


def check_subnets(out: dict) -> None:
    ec2 = client("ec2")
    ids = out["public_subnet_ids"] + out["private_subnet_ids"] + out["database_subnet_ids"]
    subnets = ec2.describe_subnets(SubnetIds=ids)["Subnets"]
    assert len(subnets) == 6, f"expected 6 subnets, found {len(subnets)}"
    zones = {s["AvailabilityZone"] for s in subnets}
    assert len(zones) == 2, f"subnets must span 2 AZs, found {sorted(zones)}"
    public = [s for s in subnets if s["SubnetId"] in out["public_subnet_ids"]]
    assert not any(s["MapPublicIpOnLaunch"] for s in public), "public subnets must not auto-assign public IPs"


def check_nat_per_az(out: dict) -> None:
    ec2 = client("ec2")
    nats = ec2.describe_nat_gateways(NatGatewayIds=out["nat_gateway_ids"])["NatGateways"]
    assert len(nats) == 2, f"expected one NAT per AZ (2), found {len(nats)}"
    assert {n["SubnetId"] for n in nats} <= set(out["public_subnet_ids"]), "NAT gateways must live in public subnets"


def default_route_targets(ec2, subnet_id: str) -> list[dict]:
    tables = ec2.describe_route_tables(Filters=[{"Name": "association.subnet-id", "Values": [subnet_id]}])
    routes = [r for t in tables["RouteTables"] for r in t["Routes"]]
    return [r for r in routes if r.get("DestinationCidrBlock") == "0.0.0.0/0"]


def check_routing(out: dict) -> None:
    ec2 = client("ec2")
    for subnet in out["database_subnet_ids"]:
        assert not default_route_targets(ec2, subnet), f"database subnet {subnet} must have no internet route"
    for subnet in out["private_subnet_ids"]:
        targets = default_route_targets(ec2, subnet)
        assert targets and all("NatGatewayId" in r for r in targets), f"private subnet {subnet} must egress via NAT"
    for subnet in out["public_subnet_ids"]:
        targets = default_route_targets(ec2, subnet)
        assert targets and all(r.get("GatewayId", "").startswith("igw-") for r in targets), (
            f"public subnet {subnet} must route through the internet gateway"
        )


def check_database_isolation(out: dict) -> None:
    ec2 = client("ec2")
    ingress = [r for r in sg_rules(ec2, out["rds_security_group_id"]) if not r["IsEgress"]]
    assert len(ingress) == 1, f"database SG must have exactly one ingress rule, found {len(ingress)}"
    rule = ingress[0]
    source = strip_account(rule.get("ReferencedGroupInfo", {}).get("GroupId"))
    assert source == out["ecs_security_group_id"], f"database must only admit the ECS SG, admits {source}"
    assert (rule["FromPort"], rule["ToPort"]) == (5432, 5432), "database must only expose 5432"
    assert not rule.get("CidrIpv4"), "database must not admit any CIDR range"


def check_service_egress(out: dict) -> None:
    ec2 = client("ec2")
    egress = [r for r in sg_rules(ec2, out["ecs_security_group_id"]) if r["IsEgress"]]
    to_internet = [r for r in egress if r.get("CidrIpv4") == "0.0.0.0/0"]
    assert len(to_internet) == 1, f"exactly one internet egress rule expected, found {len(to_internet)}"
    assert (to_internet[0]["FromPort"], to_internet[0]["ToPort"]) == (443, 443), "internet egress must be HTTPS only"


def check_flow_logs(out: dict) -> None:
    logs = client("ec2").describe_flow_logs(Filters=[{"Name": "resource-id", "Values": [out["vpc_id"]]}])
    assert logs["FlowLogs"], "VPC flow logs must be enabled"
    assert logs["FlowLogs"][0]["TrafficType"] == "ALL", "flow logs must capture all traffic"


def check_state_bucket(out: dict) -> None:
    s3 = client("s3")
    bucket = out["state_bucket_name"]
    assert s3.get_bucket_versioning(Bucket=bucket).get("Status") == "Enabled", "state bucket must be versioned"
    block = s3.get_public_access_block(Bucket=bucket)["PublicAccessBlockConfiguration"]
    assert all(block.values()), f"all public access must be blocked: {block}"
    rule = s3.get_bucket_encryption(Bucket=bucket)["ServerSideEncryptionConfiguration"]["Rules"][0]
    assert rule["ApplyServerSideEncryptionByDefault"]["SSEAlgorithm"] == "aws:kms", "state must be KMS-encrypted"
    policy = json.loads(s3.get_bucket_policy(Bucket=bucket)["Policy"])
    denies_http = any(
        st["Effect"] == "Deny" and st.get("Condition", {}).get("Bool", {}).get("aws:SecureTransport") == "false"
        for st in policy["Statement"]
    )
    assert denies_http, "bucket policy must deny non-TLS requests"


def check_lock_table(out: dict) -> None:
    table = client("dynamodb").describe_table(TableName=out["lock_table_name"])["Table"]
    assert table["KeySchema"] == [{"AttributeName": "LockID", "KeyType": "HASH"}], "lock table needs a LockID hash key"
    assert table["BillingModeSummary"]["BillingMode"] == "PAY_PER_REQUEST", "lock table should be on-demand"


def check_app_secret(out: dict) -> None:
    secret = client("secretsmanager").describe_secret(SecretId=out["ai_service_secret_name"])
    assert secret["Name"] == out["ai_service_secret_name"], "AI service secret must exist"


CHECKS: list[tuple[str, Callable[[dict], None]]] = [
    ("VPC exists with DNS hostnames", check_vpc),
    ("6 subnets across 2 AZs, no auto public IPs", check_subnets),
    ("One NAT gateway per AZ", check_nat_per_az),
    ("Routing: public->IGW, private->NAT, database->none", check_routing),
    ("Database SG admits only ECS on 5432", check_database_isolation),
    ("Services egress to internet on 443 only", check_service_egress),
    ("VPC flow logs capture all traffic", check_flow_logs),
    ("State bucket: versioned, private, KMS, TLS-only", check_state_bucket),
    ("Lock table: LockID key, on-demand", check_lock_table),
    ("AI service secret exists", check_app_secret),
]


def drift(plan: dict) -> list[str]:
    """Return resources a second plan would change, ignoring documented emulator quirks."""
    problems = []
    for rc in plan.get("resource_changes", []):
        actions = rc["change"]["actions"]
        if actions == ["no-op"]:
            continue
        before, after = rc["change"]["before"] or {}, rc["change"]["after"] or {}
        changed = {k for k in set(before) | set(after) if before.get(k) != after.get(k)}
        quirks = EMULATOR_QUIRKS.get(rc["type"], {})
        cosmetic = actions == ["update"] and all(
            k in quirks and quirks[k](before.get(k), after.get(k)) for k in changed
        )
        if not cosmetic:
            problems.append(f"{rc['address']}: {'/'.join(actions)} {sorted(changed)}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("outputs", help="terraform output -json")
    parser.add_argument("--plan", help="terraform show -json of a plan made after apply (drift check)")
    args = parser.parse_args()

    with open(args.outputs, encoding="utf-8") as f:
        outputs = {k: v["value"] for k, v in json.load(f).items()}

    failures = 0
    for title, check in CHECKS:
        try:
            check(outputs)
            print(f"PASS  {title}")
        except (AssertionError, KeyError, IndexError) as exc:
            failures += 1
            print(f"FAIL  {title}: {exc}")

    if args.plan:
        with open(args.plan, encoding="utf-8") as f:
            problems = drift(json.load(f))
        if problems:
            failures += 1
            print("FAIL  No drift after apply (idempotency):")
            for p in problems:
                print(f"        {p}")
        else:
            print("PASS  No drift after apply (idempotency)")

    total = len(CHECKS) + (1 if args.plan else 0)
    print(f"\n{total - failures}/{total} checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
