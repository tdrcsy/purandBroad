#!/bin/bash
set -e

# ------------------------------
# 用户可修改变量
# ------------------------------
CONTAINER_NAME=${CONTAINER_NAME:-KalDev}
PASSWORD=${PASSWORD:-Kal1349..}
DEFAULT_PORT=${DEFAULT_PORT:-8080}
PROJECT_DIR=${PROJECT_DIR:-/home/kal/dev}
CONFIG_DIR=${CONFIG_DIR:-/home/kal/dev-config}
DOMAIN_NAME=${DOMAIN_NAME:-dev.930009.xyz}
TUNNEL_NAME=${TUNNEL_NAME:-KalDevTunnel}
CODE_SERVER_IMAGE=${CODE_SERVER_IMAGE:-codercom/code-server:latest}

# ------------------------------
# 1. 清理旧 Docker
# ------------------------------
echo "[INFO] 清理旧 Docker / containerd ..."
sudo apt remove -y docker docker-engine docker.io containerd runc || true
sudo apt purge -y docker docker-engine docker.io containerd runc || true
sudo apt autoremove -y || true

# ------------------------------
# 2. 安装 Docker
# ------------------------------
echo "[INFO] 安装 Docker ..."
sudo apt update
sudo apt install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io
sudo systemctl enable --now docker
docker --version

# ------------------------------
# 3. 安装 cloudflared
# ------------------------------
echo "[INFO] 安装 cloudflared ..."
curl -fsSL https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/linux/cloudflared-install.sh | sudo bash
cloudflared --version

# ------------------------------
# 4. 创建项目和配置目录
# ------------------------------
echo "[INFO] 创建目录并设置权限..."
sudo mkdir -p "$PROJECT_DIR" "$CONFIG_DIR/share/code-server/extensions"
sudo touch "$CONFIG_DIR/share/code-server/extensions/extensions.json"
sudo chown -R 1000:1000 "$PROJECT_DIR" "$CONFIG_DIR"
sudo chmod -R 755 "$PROJECT_DIR" "$CONFIG_DIR"

# ------------------------------
# 5. 检查端口
# ------------------------------
PORT=$DEFAULT_PORT
while lsof -i:$PORT >/dev/null 2>&1; do
    echo "[WARN] 端口 $PORT 已被占用，尝试下一个端口..."
    PORT=$((PORT+1))
done
echo "[INFO] 使用端口 $PORT"

# ------------------------------
# 6. 创建 Cloudflare Tunnel
# ------------------------------
TUNNEL_FILE="/root/.cloudflared/${TUNNEL_NAME}.json"
if [ ! -f "$TUNNEL_FILE" ]; then
    echo "[INFO] 创建 Cloudflare Tunnel: $TUNNEL_NAME ..."
    cloudflared tunnel create "$TUNNEL_NAME"
else
    echo "[INFO] 使用已有隧道: $TUNNEL_NAME ($TUNNEL_FILE)"
fi

# 确保 cloudflared 配置目录存在
sudo mkdir -p /etc/cloudflared
CONFIG_FILE="/etc/cloudflared/config.yml"

echo "[INFO] 写入 Cloudflare Tunnel 配置..."
sudo tee "$CONFIG_FILE" >/dev/null <<EOF
tunnel: $(basename $TUNNEL_FILE .json)
credentials-file: $TUNNEL_FILE

ingress:
  - hostname: $DOMAIN_NAME
    service: http://localhost:$PORT
  - service: http_status:404
EOF

# ------------------------------
# 7. 启动 code-server 容器
# ------------------------------
echo "[INFO] 拉取最新 code-server 镜像..."
docker pull $CODE_SERVER_IMAGE

echo "[INFO] 启动容器 $CONTAINER_NAME ..."
docker stop $CONTAINER_NAME >/dev/null 2>&1 || true
docker rm $CONTAINER_NAME >/dev/null 2>&1 || true

docker run -d \
    --name $CONTAINER_NAME \
    --restart unless-stopped \
    -p $PORT:8080 \
    -e PASSWORD="$PASSWORD" \
    -v "$PROJECT_DIR":/home/coder/projects \
    -v "$CONFIG_DIR":/home/coder/.local \
    $CODE_SERVER_IMAGE

# ------------------------------
# 8. 启动 cloudflared 隧道
# ------------------------------
echo "[INFO] 启动 Cloudflare Tunnel ..."
sudo cloudflared service install || echo "[WARN] 请手动执行 'cloudflared service install' 然后 'sudo systemctl start cloudflared'"

# ------------------------------
# 9. 输出信息
# ------------------------------
echo "===================================="
echo "✅ DevSpace 部署完成!"
echo "容器名称: $CONTAINER_NAME"
echo "项目目录: $PROJECT_DIR"
echo "配置目录: $CONFIG_DIR"
echo "访问地址: https://$DOMAIN_NAME"
echo "宿主机端口: $PORT"
echo "Cloudflare 隧道: $TUNNEL_NAME"
echo "===================================="
