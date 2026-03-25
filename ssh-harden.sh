#!/bin/bash

# 检查权限
if [ "$EUID" -ne 0 ]; then 
  echo "错误：请以 root 权限运行此脚本 (Error: Please run as root)"
  exit 1
fi

# 1. 创建用户
echo -e "\n--- 用户创建 | User Creation ---"
read -p "请输入用户名 (Enter username): " username
if id "$username" &>/dev/null; then
    echo "用户 $username 已存在。"
else
    adduser "$username"
fi

# 2. 赋予 sudo 权限
usermod -aG sudo "$username"
echo "已将 $username 添加至 sudo 组。"

# 3. SSH 公钥配置
echo -e "\n--- SSH 公钥配置 | SSH Key Setup ---"
user_home="/home/$username"
sudo -u "$username" mkdir -p "$user_home/.ssh"

echo "请在此处粘贴您的 SSH 公钥 (Please paste your SSH Public Key):"
read -r public_key
echo "$public_key" | sudo -u "$username" tee "$user_home/.ssh/authorized_keys" > /dev/null

chmod 700 "$user_home/.ssh"
chmod 600 "$user_home/.ssh/authorized_keys"
chown -R "$username:$username" "$user_home/.ssh"

# 4. 交互式 SSH 安全配置
echo -e "\n--- SSH 安全设置选项 | SSH Configuration ---"
ssh_port=22
pwd_auth="yes"
permit_root="yes"
allow_users_line=""

read -p "是否修改默认端口 22? (Change SSH port? [y/n]): " c_port
[[ "$c_port" =~ ^[Yy]$ ]] && read -p "请输入新端口号: " ssh_port

read -p "是否禁用密码登录? (Disable password login? [y/n]): " c_pwd
[[ "$c_pwd" =~ ^[Yy]$ ]] && pwd_auth="no"

read -p "是否禁止 Root 登录? (Disable Root login? [y/n]): " c_root
[[ "$c_root" =~ ^[Yy]$ ]] && permit_root="no"

read -p "是否仅允许 $username 登录? (Only allow $username? [y/n]): " c_user
[[ "$c_user" =~ ^[Yy]$ ]] && allow_users_line="AllowUsers $username"

# 写入配置
mkdir -p /etc/ssh/sshd_config.d/
config_file="/etc/ssh/sshd_config.d/ssh.conf"
cat <<EOF > $config_file
Port $ssh_port
PasswordAuthentication $pwd_auth
PermitRootLogin $permit_root
$allow_users_line
EOF

# 5. 重启与安全警告
echo -e "\n\033[31m!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo -e "关键警告 (CRITICAL WARNING):"
echo -e "重启 SSHD 后，请【务必保留当前窗口】不要关闭！"
echo -e "立即【新开一个终端窗口】尝试使用新用户和新端口登录。"
echo -e "如果新窗口登录失败，你可以在当前窗口即时修复配置，否则将彻底无法连接！"
echo -e "----------------------------------------------------------------"
echo -e "After restarting SSHD, DO NOT close this current window!"
echo -e "Immediately open a NEW terminal window to test the login."
echo -e "If it fails, you can still fix it in this session."
echo -e "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\033[0m\n"

read -p "是否立即重启 SSHD 以应用更改? (Restart SSHD now? [y/n]): " restart_sshd

if [[ "$restart_sshd" =~ ^[Yy]$ ]]; then
    systemctl restart sshd
    echo -e "\n[✔] SSHD 已重启！"
    echo -e "测试命令建议: ssh -p $ssh_port $username@$(curl -s ifconfig.me)"
else
    echo -e "\n[!] 已跳过重启。手动重启命令: sudo systemctl restart sshd"
fi
