#!/bin/bash
set -e

# ============================
# 默认变量
# ============================
read -p "输入容器名称 (默认 KalDev): " CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-KalDev}

read -p "输入 code-server 密码 (默认 Kal1349..): " PASSWORD
PASSWORD=${PASSWORD:-Kal1349..}

read -p "输入宿主机端口 (默认 8080): " DEFAULT_PORT
DEFAULT_PORT=${DEFAULT_PORT:-8080}

read -p "输入项目目录 (默认 /home/kal/dev): " PROJECT_DIR
PROJECT_DIR=${PROJECT_DIR:-/home/kal/dev}

read -p "输入配置目录 (默认 /home/kal/dev-config): " CONFIG_DIR
CONFIG_DIR=${CONFIG_DIR:-/home/kal/dev-config}

read -p "输入域名 (默认 dev.930009.xyz): " DOMAIN_NAME
DOMAIN_NAME=${DOMAIN_NAME:-dev.930009.xyz}

read -p "输入 Cloudflare 隧道名称 (默认 KalDevTunnel): " TUNNEL_NAME
TUNNEL_NAME=${TUNNEL_NAME:-KalDevTunnel}

CODE_SERVER_IMAGE="codercom/code-server:latest"

# ============================
# 1. 检查依赖
# ============================
for cmd in docker cloudflared lsof; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "[INFO] $cmd 未安装"
        if [ "$cmd" = "docker" ]; then
            echo "[INFO] 安装 Docker..."
            curl -fsSL https://get.docker.com | sh
        elif [ "$cmd" = "cloudflared" ]; then
            echo "[ERROR] cloudflared 未安装，请先安装: https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/"
            exit 1
        else
            echo "[ERROR] 依赖 $cmd 缺失"
            exit 1
        fi
    fi
done

# ============================
# 2. 创建目录
# ============================
mkdir -p "$PROJECT_DIR" "$CONFIG_DIR"
chmod -R 755 "$PROJECT_DIR" "$CONFIG_DIR"

# ============================
# 3. 检测可用端口
# ============================
HOST_PORT=$DEFAULT_PORT
while lsof -i:$HOST_PORT >/dev/null 2>&1; do
    echo "[WARN] 端口 $HOST_PORT 被占用，尝试下一个端口"
    HOST_PORT=$((HOST_PORT+1))
done
echo "[INFO] 使用端口 $HOST_PORT"

# ============================
# 4. 停止并删除旧容器
# ============================
if docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
    echo "[INFO] 停止并删除已有容器 $CONTAINER_NAME"
    docker stop $CONTAINER_NAME
    docker rm $CONTAINER_NAME
fi

# ============================
# 5. 拉取最新 code-server 镜像
# ============================
docker pull $CODE_SERVER_IMAGE

# ============================
# 6. 启动 code-server 容器
# ============================
docker run -d \
  --name $CONTAINER_NAME \
  --restart unless-stopped \
  -p $HOST_PORT:8080 \
  -e PASSWORD="$PASSWORD" \
  -v "$PROJECT_DIR":/home/coder/projects \
  -v "$CONFIG_DIR":/home/coder/.local \
  $CODE_SERVER_IMAGE

echo "[INFO] code-server 容器 $CONTAINER_NAME 已启动"

# ============================
# 7. Cloudflare 隧道处理
# ============================
CREDENTIAL_FILE=$(cloudflared tunnel list | awk -v name="$TUNNEL_NAME" '$2==name {print $1}')
if [ -z "$CREDENTIAL_FILE" ]; then
    echo "[INFO] 隧道 $TUNNEL_NAME 不存在，创建..."
    cloudflared tunnel create $TUNNEL_NAME
    CREDENTIAL_FILE=$(cloudflared tunnel list | awk -v name="$TUNNEL_NAME" '$2==name {print $1}')
fi

CREDENTIAL_PATH="/root/.cloudflared/${CREDENTIAL_FILE}.json"
mkdir -p /etc/cloudflared
cat > /etc/cloudflared/config.yml <<EOF
tunnel: $CREDENTIAL_FILE
credentials-file: $CREDENTIAL_PATH

ingress:
  - hostname: $DOMAIN_NAME
    service: http://localhost:$HOST_PORT
  - service: http_status:404
EOF

# ============================
# 8. 安装 systemd 服务
# ============================
sudo cloudflared service install || true
sudo systemctl enable cloudflared
sudo systemctl restart cloudflared || true

# ============================
# 9. 输出信息
# ============================
echo "========================================="
echo "✅ code-server 部署完成!"
echo "容器名称: $CONTAINER_NAME"
echo "项目目录: $PROJECT_DIR"
echo "配置目录: $CONFIG_DIR"
echo "访问地址: https://$DOMAIN_NAME"
echo "宿主机端口: $HOST_PORT"
echo "Cloudflare 隧道: $TUNNEL_NAME (UUID: $CREDENTIAL_FILE)"
echo "========================================="
