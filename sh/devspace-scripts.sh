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

# Cloudflared 隧道文件
TUNNEL_ID_FILE="/root/.cloudflared/69c0f02a-f5af-4498-b85d-b9becb0d915e.json"
CONFIG_FILE="/etc/cloudflared/config.yml"

CODE_SERVER_IMAGE="codercom/code-server:latest"

# ============================
# 1. 系统依赖检查
# ============================
echo "====================================================="
echo " DevSpace final deploy/upgrade script"
echo " Container: $CONTAINER_NAME | Domain: $DOMAIN_NAME"
echo " Project dir: $PROJECT_DIR | Config dir: $CONFIG_DIR"
echo "====================================================="
echo "[INFO] 检查系统依赖..."
for cmd in docker cloudflared lsof; do
    command -v $cmd >/dev/null 2>&1 || { echo "[ERROR] $cmd 未安装"; exit 1; }
done

# ============================
# 2. 创建并设置目录
# ============================
echo "[INFO] 创建并设置项目/配置目录..."
mkdir -p "$PROJECT_DIR" "$CONFIG_DIR/share/code-server/extensions"
chmod -R 755 "$PROJECT_DIR" "$CONFIG_DIR"
chown -R 1000:1000 "$PROJECT_DIR" "$CONFIG_DIR"

# 初始化 extensions.json
EXT_JSON="$CONFIG_DIR/share/code-server/extensions/extensions.json"
if [ ! -f "$EXT_JSON" ]; then
    touch "$EXT_JSON"
fi

# ============================
# 3. 检查磁盘空间
# ============================
AVAILABLE=$(df "$PROJECT_DIR" | tail -1 | awk '{print $4}')
if [ "$AVAILABLE" -lt 1048576 ]; then
    echo "[WARN] 剩余空间 < 1GB，可能启动失败"
fi

# ============================
# 4. 端口检测和释放
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
            echo "[INFO] 端口 $port 被 Docker 容器 $DOCKER_CONTAINER 占用，正在停止并删除..."
            docker stop $DOCKER_CONTAINER
            docker rm $DOCKER_CONTAINER
            echo "[INFO] 已释放端口 $port"
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
echo "[INFO] 将使用宿主机端口: $HOST_PORT"

# ============================
# 5. 停止并删除旧容器
# ============================
EXISTING_CONTAINER=$(docker ps -a -q -f name=$CONTAINER_NAME)
if [ -n "$EXISTING_CONTAINER" ]; then
    echo "[INFO] 停止并删除已有容器 $CONTAINER_NAME ..."
    docker stop $CONTAINER_NAME
    docker rm $CONTAINER_NAME
fi

# ============================
# 6. 拉取最新 code-server 镜像
# ============================
echo "[INFO] 拉取最新镜像 $CODE_SERVER_IMAGE ..."
docker pull $CODE_SERVER_IMAGE

# ============================
# 7. 启动 code-server 容器
# ============================
echo "[INFO] 启动容器 $CONTAINER_NAME (端口 $HOST_PORT -> 容器 8080) ..."
docker run -d \
  --name $CONTAINER_NAME \
  --restart unless-stopped \
  -p $HOST_PORT:8080 \
  -e PASSWORD="$PASSWORD" \
  -e CUSTOM_WELCOME_MESSAGE="$CUSTOM_WELCOME" \
  -v "$PROJECT_DIR":/home/coder/projects \
  -v "$CONFIG_DIR":/home/coder/.local \
  $CODE_SERVER_IMAGE

# ============================
# 8. Cloudflare Tunnel 配置
# ============================
if [ ! -f "$TUNNEL_ID_FILE" ]; then
    echo "[ERROR] Cloudflared 隧道凭证文件不存在: $TUNNEL_ID_FILE"
    echo "请先在该机器上执行: cloudflared tunnel create <name>"
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

echo "[INFO] 重启 cloudflared 隧道服务..."
sudo systemctl restart cloudflared
sudo systemctl enable cloudflared

# ============================
# 9. 完成输出
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
