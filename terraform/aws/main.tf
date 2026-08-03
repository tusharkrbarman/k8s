resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = local.adopted_tags

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = local.adopted_tags

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_subnet" "private" {
  for_each = local.private_subnet_specs

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value.cidr
  map_public_ip_on_launch = false

  tags = var.adopt_existing ? null : merge(local.tags, {
    Name                                        = "${var.cluster_name}-private-${each.key}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  })

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_subnet" "public" {
  for_each = local.public_subnet_specs

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value.cidr
  map_public_ip_on_launch = var.adopt_existing ? false : true

  tags = var.adopt_existing ? null : merge(local.tags, {
    Name                                        = "${var.cluster_name}-public-${each.key}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  })

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = local.adopted_tags

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_main_route_table_association" "private" {
  count = var.adopt_existing ? 0 : 1

  vpc_id         = aws_vpc.this.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = local.adopted_tags

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = local.adopted_tags

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[var.availability_zones[0]].id

  depends_on = [aws_internet_gateway.this]
  tags       = local.adopted_tags

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_security_group" "internal_alb" {
  name        = "${var.cluster_name}-internal-alb"
  description = "Allow HTTP traffic only"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.trusted_private_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.adopt_existing ? null : merge(local.tags, {
    Name = "${var.cluster_name}-internal-alb"
  })

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.cluster_name}-vpc-endpoints"
  description = "Allowing internal traffic to reach the AWS services"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.adopt_existing ? null : merge(local.tags, {
    Name = "${var.cluster_name}-vpc-endpoints"
  })

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = local.adopted_tags

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoint_services

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = values(aws_subnet.private)[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = local.adopted_tags

  lifecycle {
    ignore_changes = [tags]
  }
}
