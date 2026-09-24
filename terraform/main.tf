# ===========================================================================
#  AWS build of the isolated AD lab.
#  Terraform's ONLY job here is to create the four VMs, put them on a private
#  10.10.10.0/24 subnet, enable WinRM on the Windows hosts, and lock remote
#  access to your IP. Everything else (the domain, users, the deliberate
#  misconfigurations, the flags) is done afterwards by the existing Ansible.
# ===========================================================================

# --- Latest AMIs ------------------------------------------------------------
data "aws_ami" "windows" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = [var.windows_ami_pattern]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# --- Network ----------------------------------------------------------------
resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "${var.project}-igw" }
}

resource "aws_subnet" "lab" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = var.subnet_cidr
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-subnet" }
}

resource "aws_route_table" "lab" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }
  tags = { Name = "${var.project}-rt" }
}

resource "aws_route_table_association" "lab" {
  subnet_id      = aws_subnet.lab.id
  route_table_id = aws_route_table.lab.id
}

# --- Security group ---------------------------------------------------------
resource "aws_security_group" "lab" {
  name        = "${var.project}-sg"
  description = "Lab hosts: full mesh internally; management ports from operator only"
  vpc_id      = aws_vpc.lab.id

  # Everything between lab hosts (AD needs many ports: DNS/LDAP/Kerberos/SMB/RPC)
  ingress {
    description = "intra-lab all"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  # Management access from your IP only
  ingress {
    description = "RDP from operator"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = [var.operator_cidr]
  }
  ingress {
    description = "WinRM from operator"
    from_port   = 5985
    to_port     = 5986
    protocol    = "tcp"
    cidr_blocks = [var.operator_cidr]
  }
  ingress {
    description = "SSH from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.operator_cidr]
  }

  egress {
    description = "all egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-sg" }
}

# --- Key pair (for the Linux pivot) ----------------------------------------
resource "aws_key_pair" "lab" {
  key_name   = "${var.project}-key"
  public_key = file(pathexpand(var.public_key_path))
}

# --- Windows hosts ----------------------------------------------------------
locals {
  windows_hosts = merge(
    {
      dc01  = var.win_server_instance_type
      srv01 = var.win_server_instance_type
    },
    var.enable_ws01 ? { ws01 = var.win_client_instance_type } : {}
  )
}

resource "aws_instance" "windows" {
  for_each = local.windows_hosts

  ami                    = data.aws_ami.windows.id
  instance_type          = each.value
  subnet_id              = aws_subnet.lab.id
  private_ip             = var.private_ips[each.key]
  key_name               = aws_key_pair.lab.key_name
  vpc_security_group_ids = [aws_security_group.lab.id]

  user_data = templatefile("${path.module}/templates/windows_userdata.ps1.tpl", {
    hostname       = each.key
    admin_password = var.admin_password
  })

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }
  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }
  tags = { Name = each.key, Role = "windows" }
}

# --- Linux pivot ------------------------------------------------------------
resource "aws_instance" "pivot" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.linux_instance_type
  subnet_id              = aws_subnet.lab.id
  private_ip             = var.private_ips["pivot"]
  key_name               = aws_key_pair.lab.key_name
  vpc_security_group_ids = [aws_security_group.lab.id]

  metadata_options {
    http_tokens = "required"
  }
  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }
  tags = { Name = "pivot", Role = "linux" }
}
