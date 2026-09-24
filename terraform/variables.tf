# ---------------------------------------------------------------------------
# Inputs for the AWS build of the lab. Set the required ones in a
# terraform.tfvars file (copy terraform.tfvars.example) or via TF_VAR_*.
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to build the lab in."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Tag/name prefix for all resources."
  type        = string
  default     = "vulnlab"
}

variable "operator_cidr" {
  description = "YOUR public IP as a /32 (e.g. 203.0.113.4/32). RDP/WinRM/SSH are opened ONLY to this. Never use 0.0.0.0/0."
  type        = string
}

variable "public_key_path" {
  description = "Path to the SSH public key used for the Linux pivot and EC2 key pair."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "admin_password" {
  description = "Local Administrator / domain admin password set on the Windows hosts. MUST match lab_domain_admin_password in inventory-aws/group_vars/windows.yml."
  type        = string
  sensitive   = true
  default     = "Passw0rd!Admin#2026"
}

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.10.0.0/16"
}

variable "subnet_cidr" {
  description = "Lab subnet CIDR. Keep it 10.10.10.0/24 so the private IPs match the Ansible variables."
  type        = string
  default     = "10.10.10.0/24"
}

# Private IPs MUST match inventory group_vars (lab_dns_server=10.10.10.10, etc.)
variable "private_ips" {
  description = "Static private IPs per host."
  type        = map(string)
  default = {
    dc01  = "10.10.10.10"
    srv01 = "10.10.10.20"
    ws01  = "10.10.10.30"
    pivot = "10.10.10.5"
  }
}

variable "win_server_instance_type" {
  description = "Instance type for the DC and member server (need ~8GB)."
  type        = string
  default     = "t3.large"
}

variable "win_client_instance_type" {
  description = "Instance type for the workstation."
  type        = string
  default     = "t3.medium"
}

variable "linux_instance_type" {
  description = "Instance type for the Linux pivot."
  type        = string
  default     = "t3.small"
}

variable "enable_ws01" {
  description = "Set false to skip the workstation and save cost."
  type        = bool
  default     = true
}

variable "windows_ami_pattern" {
  description = "AMI name filter for Windows Server."
  type        = string
  default     = "Windows_Server-2022-English-Full-Base-*"
}
