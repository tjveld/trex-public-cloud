# ==============================================================================
# Network Module (VPC)
# ==============================================================================
# Creates a VPC, its subnets, and an Internet Gateway. Route tables and
# associations are handled separately by the routing module.

resource "aws_vpc" "this" {
  cidr_block = var.cidr_blocks[0]
  tags       = merge(var.tags, { Name = var.name })
}

# Any CIDR blocks beyond the first, associated after the VPC's primary one -
# each just needs to be non-overlapping, not contiguous.
resource "aws_vpc_ipv4_cidr_block_association" "this" {
  for_each = toset(slice(var.cidr_blocks, 1, length(var.cidr_blocks)))

  vpc_id     = aws_vpc.this.id
  cidr_block = each.value
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-igw" })
}

resource "aws_subnet" "this" {
  for_each = var.subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr_block
  availability_zone = each.value.availability_zone
  tags              = merge(var.tags, { Name = "${var.name}-${each.key}" })

  # A subnet carved from a secondary CIDR must wait for that range's
  # association first, or AWS rejects it.
  depends_on = [aws_vpc_ipv4_cidr_block_association.this]
}
