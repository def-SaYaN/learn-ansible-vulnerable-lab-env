# Render the Ansible inventory from the live instance public IPs.
resource "local_file" "inventory" {
  filename = "${path.module}/../inventory/hosts.ini"
  content = templatefile("${path.module}/templates/inventory.ini.tpl", {
    dc01_public_ip  = aws_instance.windows["dc01"].public_ip
    srv01_line      = "srv01 ansible_host=${aws_instance.windows["srv01"].public_ip}"
    ws01_line       = var.enable_ws01 ? "ws01  ansible_host=${try(aws_instance.windows["ws01"].public_ip, "")}" : "# ws01 disabled (enable_ws01=false)"
    pivot_public_ip = aws_instance.pivot.public_ip
  })
}

output "windows_public_ips" {
  description = "Public IPs of the Windows hosts (RDP/WinRM, from your IP only)."
  value       = { for k, v in aws_instance.windows : k => v.public_ip }
}

output "pivot_public_ip" {
  description = "Public IP of the Linux pivot (SSH)."
  value       = aws_instance.pivot.public_ip
}

output "private_ips" {
  description = "Private IPs (used internally by the domain)."
  value       = var.private_ips
}

output "next_steps" {
  value = <<-EOT
    1) Wait ~5 min for the Windows hosts to finish first-boot (rename + WinRM + reboot).
    2) Confirm the generated inventory: cat inventory/hosts.ini
    3) Test connectivity:
         ansible -i inventory/hosts.ini windows -m ansible.windows.win_ping
         ansible -i inventory/hosts.ini linux_pivot -m ansible.builtin.ping
    4) Build the lab:
         ansible-playbook -i inventory/hosts.ini site.yml
    5) When done for the day, save money: terraform destroy   (or stop the instances)
  EOT
}
