# server-tools

## ssh-harden.sh 功能

1. 添加普通用户并授予管理员权限
2. 普通用户使用秘钥登录
3. 更改SSH端口
4. 禁用密码登录
5. 禁止root账户登录
6. 只允许特定用户进行SSH登录

### 使用方法

长链

```bash
bash <(curl -sSL https://raw.githubusercontent.com/NodeWardenpwd/server-tools/refs/heads/main/ssh-harden.sh)
```

短链

```bash
bash <(curl -sSL https://node.netlib.re/ssh-harden)
```

如提示未安装curl则先安装

```bash
apt-get update && apt-get install -y curl
```
