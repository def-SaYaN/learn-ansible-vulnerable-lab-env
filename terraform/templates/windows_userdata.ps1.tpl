<powershell>
# ---------------------------------------------------------------------------
# EC2 first-boot bootstrap. Purpose: rename the host, set a known local
# Administrator password, and enable WinRM so Ansible can connect. This is the
# cloud equivalent of what the Vagrant base box does for you locally.
# ---------------------------------------------------------------------------
$ErrorActionPreference = "Stop"

# 1) Known Administrator password (Ansible logs in with this).
$pw = "${admin_password}"
try { net user Administrator "$pw" } catch { }

# 2) Rename to the lab name (dc01/srv01/ws01) if not already.
if ($env:COMPUTERNAME -ne "${hostname}") {
  Rename-Computer -NewName "${hostname}" -Force -ErrorAction SilentlyContinue
}

# 3) Enable WinRM for Ansible (NTLM over 5985; message-level encryption stays on).
Enable-PSRemoting -Force -SkipNetworkProfileCheck
winrm quickconfig -quiet
if (-not (Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -match "Transport=HTTP" })) {
  New-Item -Path WSMan:\localhost\Listener -Transport HTTP -Address * -Force
}
winrm set winrm/config/service '@{AllowUnencrypted="false"}'
winrm set winrm/config/service/auth '@{Negotiate="true"}'
winrm set winrm/config/service/auth '@{Basic="false"}'
winrm set winrm/config '@{MaxTimeoutms="1800000"}'

# 4) Firewall + service.
New-NetFirewallRule -DisplayName "WinRM 5985" -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow -ErrorAction SilentlyContinue
Set-Service -Name WinRM -StartupType Automatic
Start-Service WinRM

# 5) Reboot so the rename takes effect before Ansible promotes/joins.
Restart-Computer -Force
</powershell>
