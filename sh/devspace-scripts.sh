#!/bin/bash
set -e

# ============================
# 用户自定义变量
# ============================
CONTAINER_NAME="KalDev"
PASSWORD="Kal1349.."
DEFAULT_PORT=8080
PROJECT_DIR="/home/kal/dev"
CONFIG_DIR="/home/kal/dev-config"
CUSTOM_WELCOME="Welcome back Kal, this is your DevSpace, please enter your PASSWORD below to log in."
DOMAIN_NAME="dev.930009.xyz"
TUNNEL_ID_FILE="/root/.cloudflared/KalDevTunnel.json"
CONFIG_FILE="/etc/cloudflared/config.yml"
CODE_SERVER_IMAGE="codercom/code-server:latest"

# ============================
# 1. 系统检查与目录初始化
# ============================
echo "[INFO] 检查系统依赖..."
for cmd in docker cloudflared lsof; do
    command -v $cmd >/dev/null 2>&1 || { echo "[ERROR] $cmd 未安装"; exit 1; }
done

echo "[INFO] 创建并设置项目/配置目录..."
mkdir -p "$PROJECT_DIR" "$CONFIG_DIR/share/code-server/extensions"
touch "$CONFIG_DIR/share/code-server/extensions/extensions.json"
chown -R 1000:1000 "$PROJECT_DIR" "$CONFIG_DIR"
chmod -R 755 "$PROJECT_DIR" "$CONFIG_DIR"

# ============================
# 2. 端口检测函数
# ============================
check_port() {
    local port=$1
    local max_port=$((port+100))
    while [ $port -le $max_port ]; do
        OCCUPIED=$(lsof -i:$port -t || true)
        if [ -z "$OCCUPIED" ]; then
            echo $port
            return 0
        fi
        DOCKER_CONTAINER=$(docker ps --filter "publish=$port" --format "{{.Names}}")
        if [ -n "$DOCKER_CONTAINER" ]; then
            echo "[INFO] 停止并删除占用端口 $port 的 Docker 容器 $DOCKER_CONTAINER ..."
            docker stop $DOCKER_CONTAINER
            docker rm $DOCKER_CONTAINER
            echo "[INFO] 端口 $port 已释放"
            echo $port
            return 0
        fi
        echo "[WARN] 端口 $port 被非 Docker 进程占用，尝试下一个端口"
        port=$((port+1))
    done
    echo "[ERROR] 没有可用端口" >&2
    exit 1
}

HOST_PORT=$(check_port $DEFAULT_PORT)
echo "[INFO] 使用端口 $HOST_PORT"

# ============================
# 3. 停止并删除旧容器
# ============================
EXISTING_CONTAINER=$(docker ps -a -q -f name=$CONTAINER_NAME)
if [ -n "$EXISTING_CONTAINER" ]; then
    echo "[INFO] 停止并删除已有容器 $CONTAINER_NAME ..."
    docker stop $CONTAINER_NAME
    docker rm $CONTAINER_NAME
fi

# ============================
# 4. 拉取最新 code-server 镜像
# ============================
echo "[INFO] 拉取最新 code-server 镜像..."
docker pull $CODE_SERVER_IMAGE

# ============================
# 5. 启动 code-server 容器
# ============================
echo "[INFO] 启动容器 $CONTAINER_NAME (端口 $HOST_PORT -> 容器 8080) ..."
docker run -d \
  --name $CONTAINER_NAME \
  --restart unless-stopped \
  -p ${HOST_PORT}:8080 \
  -e PASSWORD="$PASSWORD" \
  -e CUSTOM_WELCOME_MESSAGE="$CUSTOM_WELCOME" \
  -v "$PROJECT_DIR":/home/coder/projects \
  -v "$CONFIG_DIR":/home/coder/.local \
  $CODE_SERVER_IMAGE

# ============================
# 6. 配置 Cloudflare Tunnel
# ============================
if [ ! -f "$TUNNEL_ID_FILE" ]; then
    echo "[ERROR] Cloudflared 隧道凭证文件不存在: $TUNNEL_ID_FILE"
    echo "请先执行: cloudflared tunnel create <name>"
    exit 1
fi

echo "[INFO] 更新 Cloudflare Tunnel 配置..."
sudo bash -c "cat > $CONFIG_FILE" <<EOF
tunnel: $(basename $TUNNEL_ID_FILE .json)
credentials-file: $TUNNEL_ID_FILE

ingress:
  - hostname: $DOMAIN_NAME
    service: http://localhost:$HOST_PORT
  - service: http_status:404
EOF

# ============================
# 7. 重启 Cloudflare Tunnel 服务
# ============================
echo "[INFO] 重启 cloudflared 隧道服务..."
sudo systemctl restart cloudflared
sudo systemctl enable cloudflared

# ============================
# 8. 输出信息
# ============================
echo "========================================="
echo "✅ code-server 部署/升级完成!"
echo "容器名称: $CONTAINER_NAME"
echo "项目目录: $PROJECT_DIR"
echo "配置目录: $CONFIG_DIR"
echo "访问地址: https://$DOMAIN_NAME"
echo "宿主机端口: $HOST_PORT"
echo "欢迎信息: $CUSTOM_WELCOME"
echo "========================================="
