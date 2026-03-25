#!/bin/bash

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 错误处理函数：打印错误并退出
error_exit() {
    echo -e "\n${RED}[ERROR] 出现错误: $1${NC}"
    echo -e "${YELLOW}建议建议: $2${NC}"
    exit 1
}

# 检查权限
if [ "$EUID" -ne 0 ]; then 
    error_exit "权限不足" "请使用 root 用户运行，或在命令前加 sudo。"
fi

# 交互输入函数
input() {
    read -p "$1" "$2" < /dev/tty
}

# 1. 用户创建阶段
echo -e "\n--- 用户创建 | User Creation ---"
input "请输入用户名 (Enter username): " username

if [ -z "$username" ]; then
    error_exit "用户名不能为空" "请重新运行并输入有效的用户名。"
fi

if id "$username" &>/dev/null; then
    echo -e "${GREEN}[INFO] 用户 $username 已存在，继续配置。${NC}"
else
    echo "正在创建用户 $username..."
    # 尝试创建用户并捕获错误输出
    if ! adduser "$username" 2>/tmp/adduser_err; then
        ERR_MSG=$(cat /tmp/adduser_err)
        if [[ "$ERR_MSG" == *"No space left on device"* ]]; then
            error_exit "磁盘空间不足" "系统无法写入 /etc/passwd 或 /etc/group。请清理磁盘后再试（常用命令: df -h）。"
        else
            error_exit "创建用户失败" "$ERR_MSG"
        fi
    fi
fi

# 2. 权限授予阶段
echo -e "\n--- 权限配置 | Privilege Setup ---"
if command -v usermod &>/dev/null; then
    if usermod -aG sudo "$username" 2>/dev/null; then
        echo "已成功将 $username 添加至 sudo 组。"
    elif usermod -aG wheel "$username" 2>/dev/null; then
        echo "已成功将 $username 添加至 wheel 组。"
    else
        echo -e "${YELLOW}[WARN] 无法找到 sudo 或 wheel 组，用户可能无法使用 sudo 命令。${NC}"
    fi
else
    echo -e "${YELLOW}[WARN] 未找到 usermod 命令，跳过组权限设置。${NC}"
fi

# 3. SSH 密钥配置阶段
echo -e "\n--- SSH 公钥配置 | SSH Key Setup ---"
user_home="/home/$username"
if [ ! -d "$user_home" ]; then
    error_exit "找不到家目录" "用户 $username 的家目录 $user_home 不存在，可能创建用户时出错。"
fi

mkdir -p "$user_home/.ssh" || error_exit "无法创建 .ssh 目录" "请检查文件系统权限或磁盘空间。"
echo "请在此处粘贴您的 SSH 公钥 (Please paste your SSH Public Key):"
read -r public_key < /dev/tty

if [ -z "$public_key" ]; then
    error_exit "未检测到公钥输入" "为了安全，脚本要求必须配置公钥登录，否则将无法连接。"
fi

if ! echo "$public_key" > "$user_home/.ssh/authorized_keys"; then
    error_exit "写入公钥失败" "无法写入 authorized_keys 文件，请检查磁盘空间。"
fi

# 设置权限
chmod 700 "$user_home/.ssh"
chmod 600 "$user_home/.ssh/authorized_keys"
chown -R "$username:$username" "$user_home/.ssh"
echo -e "${GREEN}[OK] SSH 密钥配置完成。${NC}"

# 4. SSH 安全设置选项
echo -e "\n--- SSH 安全设置选项 | SSH Configuration ---"
ssh_port=22; pwd_auth="yes"; permit_root="yes"; allow_users_line=""

input "是否修改默认端口 22? (Change SSH port? [y/n]): " c_port
if [[ "$c_port" =~ ^[Yy]$ ]]; then
    input "请输入新端口号 (1024-65535): " ssh_port
fi

input "是否禁用密码登录? (Disable password login? [y/n]): " c_pwd
[[ "$c_pwd" =~ ^[Yy]$ ]] && pwd_auth="no"

input "是否禁止 Root 登录? (Disable Root login? [y/n]): " c_root
[[ "$c_root" =~ ^[Yy]$ ]] && permit_root="no"

input "是否仅允许 $username 登录? (Only allow $username? [y/n]): " c_user
[[ "$c_user" =~ ^[Yy]$ ]] && allow_users_line="AllowUsers $username"

# 写入配置文件
mkdir -p /etc/ssh/sshd_config.d/
config_file="/etc/ssh/sshd_config.d/ssh.conf"
if ! cat <<EOF > $config_file
Port $ssh_port
PasswordAuthentication $pwd_auth
PermitRootLogin $permit_root
$allow_users_line
EOF
then
    error_exit "配置写入失败" "无法创建 $config_file 文件，请检查磁盘空间或 /etc/ssh 权限。"
fi

# 5. 重启与终极警示
echo -e "\n${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo -e "关键警告 (CRITICAL WARNING):"
echo -e "重启 SSHD 后，请【务必保留当前窗口】不要关闭！"
echo -e "立即【新开一个终端窗口】尝试使用新用户和新端口登录。"
echo -e "测试成功前，如果关闭此窗口，配置一旦有误你将彻底丢失访问权限！"
echo -e "----------------------------------------------------------------"
echo -e "After restarting SSHD, DO NOT close this current window!"
echo -e "Test the connection in a NEW window first."
echo -e "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}\n"

input "是否立即重启 SSHD 以应用更改? (Restart SSHD now? [y/n]): " restart_sshd

if [[ "$restart_sshd" =~ ^[Yy]$ ]]; then
    if systemctl restart sshd; then
        echo -e "\n${GREEN}[✔] SSHD 已重启成功！${NC}"
        echo -e "请使用此命令在新窗口测试: ssh -p $ssh_port $username@$(curl -s ifconfig.me || echo '你的服务器IP')"
    else
        error_exit "SSHD 重启失败" "配置可能存在冲突，请运行 'sshd -t' 检查配置文件语法。"
    fi
else
    echo -e "\n[!] 已跳过重启。稍后请手动运行: systemctl restart sshd"
fi
