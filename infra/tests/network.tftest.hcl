# Unit tests for modules/network. The AWS provider is mocked: `apply` runs entirely in
# memory, so these tests need no credentials and finish in seconds.

mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  name                  = "test"
  vpc_cidr              = "10.0.0.0/16"
  availability_zones    = ["us-east-1a", "us-east-1b"]
  public_subnet_cidrs   = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs  = ["10.0.10.0/24", "10.0.20.0/24"]
  database_subnet_cidrs = ["10.0.30.0/24", "10.0.40.0/24"]
}

run "single_nat_for_cheap_environments" {
  command = apply

  module {
    source = "./modules/network"
  }

  variables {
    single_nat_gateway = true
  }

  assert {
    condition     = length(aws_nat_gateway.nat) == 1
    error_message = "A single shared NAT gateway is expected."
  }

  assert {
    condition     = length(aws_route.private_nat) == 2 && alltrue([for r in aws_route.private_nat : r.nat_gateway_id == aws_nat_gateway.nat[0].id])
    error_message = "Every private route table must use the shared NAT gateway."
  }
}

run "one_nat_per_az_for_high_availability" {
  command = apply

  module {
    source = "./modules/network"
  }

  variables {
    single_nat_gateway = false
  }

  assert {
    condition     = length(aws_nat_gateway.nat) == 2
    error_message = "One NAT gateway per AZ is expected."
  }

  assert {
    condition     = alltrue([for i, r in aws_route.private_nat : r.nat_gateway_id == aws_nat_gateway.nat[i].id && r.route_table_id == aws_route_table.private[i].id])
    error_message = "Each private route table must use the NAT gateway in its own AZ."
  }
}

run "subnet_tiers_are_isolated" {
  command = apply

  module {
    source = "./modules/network"
  }

  assert {
    condition     = alltrue([for s in aws_subnet.public : s.map_public_ip_on_launch == false])
    error_message = "Public subnets must not auto-assign public IPs."
  }

  assert {
    condition     = alltrue([for a in aws_route_table_association.database : a.route_table_id == aws_route_table.database.id])
    error_message = "Database subnets must use the dedicated route table, which has no internet route."
  }

  assert {
    condition     = aws_route.public_internet.gateway_id == aws_internet_gateway.igw.id
    error_message = "Only the public route table may route to the internet gateway."
  }

  assert {
    condition     = length(aws_flow_log.vpc) == 1 && aws_flow_log.vpc[0].traffic_type == "ALL"
    error_message = "VPC flow logs must capture all traffic."
  }
}

run "nat_can_be_disabled" {
  command = apply

  module {
    source = "./modules/network"
  }

  variables {
    enable_nat_gateway = false
  }

  assert {
    condition     = length(aws_nat_gateway.nat) == 0 && length(aws_eip.nat) == 0
    error_message = "No NAT gateway or EIP should exist when NAT is disabled."
  }

  assert {
    condition     = length(aws_route.private_nat) == 0
    error_message = "Private route tables must have no default route without NAT."
  }
}

run "rejects_a_single_availability_zone" {
  command = plan

  module {
    source = "./modules/network"
  }

  variables {
    availability_zones = ["us-east-1a"]
  }

  expect_failures = [var.availability_zones]
}
