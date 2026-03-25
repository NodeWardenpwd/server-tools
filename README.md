# server-tools

## ssh-harden.sh 功能

1. 添加普通用户并授予管理员权限
2. 普通用户使用秘钥登录
3. 更改SSH端口
4. 禁用密码登录
5. 禁止root账户登录
6. 只允许特定用户进行SSH登录

## 使用方法

### 方式 A：使用 curl (推荐)
这是最标准的方式，脚本下载后直接通过管道传给 **bash** 执行。

长链

```bash
curl -sSL https://raw.githubusercontent.com/NodeWardenpwd/server-tools/refs/heads/main/ssh-harden.sh | sudo bash
```

短链

```bash
curl -sSL https://node.netlib.re/ssh-harden | sudo bash
```

### 方式 B：使用 wget
如果服务器上没有安装 **curl**，可以使用这个：

长链

```bash
wget -qO- https://raw.githubusercontent.com/NodeWardenpwd/server-tools/refs/heads/main/ssh-harden.sh | sudo bash
```

短链

```bash
wget -qO- https://node.netlib.re/ssh-harden | sudo bash
```
