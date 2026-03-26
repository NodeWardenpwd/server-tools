# 🛡️ SSH-Guardian: Enterprise Server Security Initialization Tool


### [中文文档]([https://](https://github.com/NodeWardenpwd/server-tools/blob/main/README-ZH.md))
This is an **industrial-grade** SSH initialization and hardening script designed specifically for Linux servers. It not only handles user creation and public key configuration but also utilizes "Isolated Configuration" and "Validity Auditing" logic to maximize server security while ensuring administrators are never accidentally locked out.

## 🌟 Key Features

* ​**🚫 Zero-Pollution Isolated Design**​: Does not forcibly modify the main `/etc/ssh/sshd_config` file. It manages custom policies through the `Include` directory and supports idempotent execution.
* ​**🛡️ Dual Anti-Lockout Mechanism**​:
  * ​**Public Key Fingerprint Verification**​: Uses `ssh-keygen -l` to pre-verify public key validity, completely eliminating login failures caused by corrupted clipboard data.
  * ​**Automatic Configuration Rollback**​: If the port is not monitoring correctly after a service restart, the script will attempt to trigger physical recovery logic to protect remote connectivity.
* ​**⚙️ Modern System Deep Adaptation**​: Automatically handles SSH Socket activation modes for Debian 12/Ubuntu, auto-fixes SELinux context labels, and supports IPv4/IPv6 dual-stack detection.
* ​**🔍 Sudoers Security Auditing**​: Rigorously validates permission syntax via `visudo -c` to prevent the loss of root privileges due to configuration errors.

## ⚠️ System Compatibility Restrictions

**This script [DOES NOT SUPPORT] the following outdated or End-of-Life (EOL) systems:**

* ❌ **CentOS 7** (EOL 2024)
* ❌ **Debian 10** (EOL)
* *Recommended Environments: Debian 11/12, Ubuntu 20.04+, Rocky/AlmaLinux 8/9, Alpine Linux.*

## 🚀 Quick Start

Please run using one of the following methods with **root** privileges:

**Short URL:**

```bash
bash <(curl -sSL https://node.netlib.re/ssh-harden)
```

**Long URL:**

```bash
bash <(curl -sSL https://raw.githubusercontent.com/NodeWardenpwd/server-tools/refs/heads/main/ssh-harden.sh)
```

## 🛠 Usage Instructions

1. ​**Preparation**​: Ensure you have root privileges.
2. ​**Execute Script**​: Copy and paste the commands above into your terminal.
3. ​**Interactive Configuration**​:
   * Enter the **Username** and **Password** to be created as prompted.
   * Paste your ​**SSH Public Key**​.
   * Choose whether to modify the default **Port 22** (Modification recommended).
   * Choose whether to **Disable Password Login** and **Disable Root Login** (Disabling recommended).
4. ​**Allow Port**​: Manually allow the newly configured SSH port in your cloud console security group/firewall.
5. ​**Verify Login**​: ​**Do not close the current window**​. Open a new terminal and attempt to log in with the new user to confirm success before exiting.

## ⚠️ Security Warnings

1. ​**External Firewalls**​: The script cannot modify control panel security groups for cloud providers (AWS, Aliyun, Tencent Cloud, etc.). You **must** manually allow the port after modification.
2. ​**AllowUsers Risk**​: If this option is enabled, no other accounts (including root) except for the new user you created will be able to log in.

## ⚙️ If "curl" is not installed, install it first

### Debian && Ubuntu

**Bash**

```bash
apt-get update && apt-get install -y curl
```

### Alpine

```bash
apk add --no-cache curl bash
```
