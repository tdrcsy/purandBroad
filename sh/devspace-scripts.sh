#!/bin/bash

# =========================================================================
# === VPS Code-server & Cloudflare Tunnel 安装脚本 (交互式) ===
# =========================================================================

# 获取用户输入
read -p "请输入你的域名 (例如: dev.example.com): " DOMAIN
read -s -p "请输入你的 Code-server 密码: " CODE_SERVER_PASSWORD
echo ""

# 固定配置
CODE_SERVER_PORT="8080"
TUNNEL_NAME="kaldev"

# --- 1. 清理旧配置和旧服务 ---
echo "--- 1. 清理旧配置和旧服务 ---"
sudo systemctl stop code-server@root 2>/dev/null
sudo systemctl disable code-server@root 2>/dev/null
sudo apt-get remove --purge code-server -y 2>/dev/null
sudo rm -rf /root/.config/code-server

sudo systemctl stop cloudflared 2>/dev/null
sudo systemctl disable cloudflared 2>/dev/null
sudo apt-get remove --purge cloudflared -y 2>/dev/null
sudo rm -rf /root/.cloudflare

# --- 2. 安装 Code-server ---
echo "--- 2. 安装 Code-server ---"
curl -fsSL https://code-server.dev/install.sh | sh
mkdir -p /root/.config/code-server

cat > /root/.config/code-server/config.yaml <<EOF
bind-addr: 127.0.0.1:${CODE_SERVER_PORT}
auth: password
password: "${CODE_SERVER_PASSWORD}"
EOF

sudo systemctl enable --now code-server@root

# 验证 Code-server 是否成功启动
if sudo systemctl is-active --quiet code-server@root; then
    echo "✅ Code-server 已成功启动。"
else
    echo "❌ Code-server 启动失败。请手动检查日志: journalctl -u code-server@root --no-pager"
    exit 1
fi

# --- 3. 安装 cloudflared ---
echo "--- 3. 安装 cloudflared ---"
sudo apt-get update
sudo apt-get install cloudflared -y

# --- 4. 登录 Cloudflare 并创建 Tunnel ---
echo "--- 4. 登录 Cloudflare 并创建 Tunnel ---"
echo "请手动执行以下命令，然后在浏览器中完成登录："
echo "cloudflared tunnel login"
echo "按下任意键继续..."
read -n 1 -s
cloudflared tunnel login

TUNNEL_ID=$(cloudflared tunnel create "${TUNNEL_NAME}" | awk '/^Created tunnel/ {print $NF}')
if [ -z "${TUNNEL_ID}" ]; then
    echo "❌ 创建 Tunnel 失败或 Tunnel 已存在。尝试获取现有 Tunnel ID..."
    TUNNEL_ID=$(cloudflared tunnel list | grep "${TUNNEL_NAME}" | awk '{print $2}')
    if [ -z "${TUNNEL_ID}" ]; then
        echo "❌ 无法获取 Tunnel ID。请手动检查 Cloudflare Dashboard。"
        exit 1
    fi
fi
echo "✅ Tunnel ID: ${TUNNEL_ID}"

# --- 5. 配置 cloudflared 并路由 DNS ---
echo "--- 5. 配置 cloudflared 并路由 DNS ---"
mkdir -p /root/.cloudflare

cat > /root/.cloudflare/config.yml <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /root/.cloudflare/${TUNNEL_ID}.json

ingress:
  - hostname: ${DOMAIN}
    service: http://localhost:${CODE_SERVER_PORT}
  - service: http_status:404
EOF

cloudflared tunnel route dns "${TUNNEL_NAME}" "${DOMAIN}"

# --- 6. 安装并启动 cloudflared 服务 ---
echo "--- 6. 安装并启动 cloudflared 服务 ---"
sudo cloudflared --config /root/.cloudflare/config.yml tunnel service install "${TUNNEL_NAME}"

# 验证 cloudflared 是否成功启动
if sudo systemctl is-active --quiet cloudflared; then
    echo "✅ Cloudflare Tunnel 已成功启动。"
else
    echo "❌ Cloudflare Tunnel 启动失败。请手动检查日志: journalctl -u cloudflared --no-pager"
    exit 1
fi

# --- 7. 处理 VS Code 扩展权限问题 ---
echo "--- 7. 处理 VS Code 扩展权限问题 ---"
echo "由于 Code-server 以 root 用户运行，扩展可能无法正确安装。"
echo "请在 Code-server 的终端中运行以下命令来修复权限："
echo "sudo chown -R root:root ~/.vscode"
echo "sudo chmod -R 755 ~/.vscode"
echo "完成上述步骤后，重启 Code-server 服务以应用更改："
echo "sudo systemctl restart code-server@root"

echo "========================================================================="
echo "✅ 全部完成！现在你可以通过 https://${DOMAIN} 访问你的远程开发环境了。"
echo "========================================================================="
