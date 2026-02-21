###############################################################################
# Locals
###############################################################################
locals {
  create_vpc            = var.create_vpc
  create_public_subnets = local.create_vpc && length(var.public_subnet_cidrs) > 0
  create_private_subnets = local.create_vpc && length(var.private_subnet_cidrs) > 0

  # Create NAT only when we have BOTH public + private subnets (common pattern)
  create_nat = local.create_public_subnets && local.create_private_subnets
}

###############################################################################
# VPC
###############################################################################
resource "aws_vpc" "main" {
  count = local.create_vpc ? 1 : 0

  cidr_block                           = var.cidr
  enable_dns_hostnames                 = var.enable_dns_hostnames
  enable_dns_support                   = var.enable_dns_support
  enable_network_address_usage_metrics = var.enable_network_address_usage_metrics

  tags = merge(
    { Name = var.project_name},
    var.tags,
    var.vpc_tags,
  )
}

###############################################################################
# Internet Gateway (only if public subnets exist)
###############################################################################
resource "aws_internet_gateway" "igw" {
  count  = local.create_public_subnets ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  tags = { Name = "${var.project_name}-igw" }
}

###############################################################################
# Public Subnets
###############################################################################
resource "aws_subnet" "public" {
  count                   = local.create_public_subnets ? length(var.public_subnet_cidrs) : 0
  vpc_id                  = aws_vpc.main[0].id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index % length(var.availability_zones)]
  map_public_ip_on_launch = true

  tags = merge(
    { Name = "${var.project_name}-public-${count.index + 1}" },
    var.tags,
  )
}

resource "aws_route_table" "public" {
  count  = local.create_public_subnets ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw[0].id
  }

  tags = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = local.create_public_subnets ? length(aws_subnet.public) : 0
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

###############################################################################
# NAT Gateway (only if we have private subnets too)
###############################################################################
resource "aws_eip" "nat" {
  count  = local.create_nat ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.project_name}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  count         = local.create_nat ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id # first public subnet
  tags          = { Name = "${var.project_name}-nat-gw" }

  depends_on = [aws_internet_gateway.igw]
}

###############################################################################
# Private Subnets
###############################################################################
resource "aws_subnet" "private" {
  count             = local.create_private_subnets ? length(var.private_subnet_cidrs) : 0
  vpc_id            = aws_vpc.main[0].id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index % length(var.availability_zones)]

  tags = merge(
    { Name = "${var.project_name}-private-${count.index + 1}" },
    var.tags,
  )
}

resource "aws_route_table" "private" {
  count  = local.create_private_subnets ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  # Only add default route if NAT exists; otherwise private subnets are isolated.
  dynamic "route" {
    for_each = local.create_nat ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.main[0].id
    }
  }

  tags = { Name = "${var.project_name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = local.create_private_subnets ? length(aws_subnet.private) : 0
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}