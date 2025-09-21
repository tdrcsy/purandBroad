#!/bin/bash
set -euo pipefail

# ----------------------------
# 最终版一键部署/升级脚本
# ----------------------------
# 使用方法：
# 1) 上传到 VPS: nano devspace-final.sh
# 2) 粘贴并保存
# 3) chmod +x devspace-final.sh
# 4) sudo ./devspace-final.sh
#
# 请先确保 Cloudflare 隧道已创建并且 TUNNEL_ID_FILE 指向正确的隧道 json 文件

# ============================
# 用户可修改区
# ============================
CONTAINER_NAME="KalDev"
PASSWORD="Kal1349.."                       # 请改为更安全的密码
DEFAULT_PORT=8080
PROJECT_DIR="/home/kal/dev"
CONFIG_DIR="/home/kal/dev-config"
CUSTOM_WELCOME="Welcome back Kal, this is your DevSpace, please enter your PASSWORD below to log in."
DOMAIN_NAME="dev.930009.xyz"

TUNNEL_ID_FILE="/root/.cloudflared/07380f7f-cee1-4be0-bc64-2b0e3461f562.json"  # 确保正确
CONFIG_FILE="/etc/cloudflared/config.yml"

CODE_SERVER_IMAGE="codercom/code-server:latest"

HEALTH_CHECK_INTERVAL=15   # 秒
HEALTH_CHECK_RETRIES=3     # 连续失败次数达到则重启容器
HEALTH_CHECK_TIMEOUT=7     # curl 超时时间（秒）
# ============================

echo "====================================================="
echo " DevSpace final deploy/upgrade script"
echo " Container: $CONTAINER_NAME | Domain: $DOMAIN_NAME"
echo " Project dir: $PROJECT_DIR | Config dir: $CONFIG_DIR"
echo "====================================================="

# ----------------------------
# 0. 依赖检查
# ----------------------------
required_cmds=(docker lsof curl tar)
for c in "${required_cmds[@]}"; do
  if ! command -v "$c" &>/dev/null; then
    echo "[ERROR] 依赖命令缺失: $c。请先安装后重试。" >&2
    exit 1
  fi
done

# ----------------------------
# 1. 初始化目录与权限
# ----------------------------
echo "[INFO] 创建并设置项目/配置目录..."
mkdir -p "$PROJECT_DIR"
mkdir -p "$CONFIG_DIR/share/code-server/extensions"
mkdir -p "$CONFIG_DIR/share/code-server/User"
mkdir -p "$CONFIG_DIR/share/code-server/CachedExtensionVSIXs"
touch "$CONFIG_DIR/share/code-server/extensions/extensions.json"

# 设置归属为容器内 coder 用户 (UID 1000) 并适当权限
echo "[INFO] 设定权限 (chown 1000:1000) ..."
sudo chown -R 1000:1000 "$PROJECT_DIR" "$CONFIG_DIR"
sudo chmod -R 755 "$PROJECT_DIR" "$CONFIG_DIR"

# 磁盘空间检查（单位为 KB）
AVAILABLE=$(df --output=avail "$PROJECT_DIR" | tail -n1 | tr -d ' ')
if [ -n "$AVAILABLE" ] && [ "$AVAILABLE" -lt $((1024*1024)) ]; then
  echo "[WARN] 剩余空间 < 1GB，可能导致拉取镜像或运行失败"
fi

# ----------------------------
# 2. 端口检测与处理函数
# ----------------------------
check_port() {
  local port=$1
  local max_port=$((port + 100))
  while [ $port -le $max_port ]; do
    local occ
    occ=$(lsof -i :"$port" -t 2>/dev/null || true)
    if [ -z "$occ" ]; then
      echo "$port"
      return 0
    fi
    # 如果是 Docker 容器占用（通过 publish 列表）
    local docker_name
    docker_name=$(docker ps --filter "publish=$port" --format "{{.Names}}" 2>/dev/null || true)
    if [ -n "$docker_name" ]; then
      echo "[INFO] 端口 $port 被 Docker 容器 $docker_name 占用，正在停止并删除该容器..."
      docker stop "$docker_name" || true
      docker rm "$docker_name" || true
      echo "[INFO] 已释放端口 $port"
      echo "$port"
      return 0
    fi
    echo "[WARN] 端口 $port 被非 Docker 进程占用，尝试下一个端口"
    port=$((port + 1))
  done
  echo "[ERROR] 未找到可用端口 (尝试范围: $1-$max_port)" >&2
  exit 1
}

HOST_PORT=$(check_port "$DEFAULT_PORT")
echo "[INFO] 将使用宿主机端口: $HOST_PORT"

# ----------------------------
# 3. 备份现有配置/扩展
# ----------------------------
BACKUP_DIR="$CONFIG_DIR/backup_$(date +%Y%m%d%H%M%S)"
EXISTING_CONTAINER=$(docker ps -a -q -f name="^${CONTAINER_NAME}$" || true)

if [ -n "$EXISTING_CONTAINER" ]; then
  echo "[INFO] 发现旧容器 $CONTAINER_NAME，将备份配置与扩展到 $BACKUP_DIR ..."
  mkdir -p "$BACKUP_DIR"
  cp -r "$CONFIG_DIR/share/code-server/User" "$BACKUP_DIR/" 2>/dev/null || true
  cp -r "$CONFIG_DIR/share/code-server/extensions" "$BACKUP_DIR/" 2>/dev/null || true

  # 保存已安装扩展列表（通过目录名）
  INSTALLED_EXTENSIONS_FILE="$BACKUP_DIR/extensions-list.txt"
  if [ -d "$CONFIG_DIR/share/code-server/extensions" ]; then
    echo "[INFO] 保存已安装扩展列表到 $INSTALLED_EXTENSIONS_FILE ..."
    ls -1 "$CONFIG_DIR/share/code-server/extensions" > "$INSTALLED_EXTENSIONS_FILE" 2>/dev/null || true
  fi

  echo "[INFO] 停止并移除旧容器 $CONTAINER_NAME ..."
  docker stop "$CONTAINER_NAME" || true
  docker rm "$CONTAINER_NAME" || true
fi

# ----------------------------
# 4. 拉取镜像
# ----------------------------
echo "[INFO] 拉取最新镜像 $CODE_SERVER_IMAGE ..."
docker pull "$CODE_SERVER_IMAGE"

# ----------------------------
# 5. 启动（或重建）容器
# ----------------------------
echo "[INFO] 启动容器 $CONTAINER_NAME (端口 $HOST_PORT -> 容器 8080) ..."
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p "$HOST_PORT":8080 \
  -e PASSWORD="$PASSWORD" \
  -e CUSTOM_WELCOME_MESSAGE="$CUSTOM_WELCOME" \
  -v "$PROJECT_DIR":/home/coder/projects \
  -v "$CONFIG_DIR":/home/coder/.local \
  "$CODE_SERVER_IMAGE"

# 确保宿主机配置目录归属正确（修正可能被容器改变的权限）
sudo chown -R 1000:1000 "$CONFIG_DIR"
sudo chmod -R 755 "$CONFIG_DIR"

# ----------------------------
# 6. 恢复扩展目录 & 自动重装缺失扩展（在容器内执行）
# ----------------------------
if [ -f "${INSTALLED_EXTENSIONS_FILE:-}" ]; then
  echo "[INFO] 检查并在容器内重新安装已保存扩展列表..."
  while IFS= read -r ext; do
    [ -z "$ext" ] && continue
    # 判断扩展目录是否已存在
    if [ ! -d "$CONFIG_DIR/share/code-server/extensions/$ext" ]; then
      echo "[INFO] 在容器内安装扩展: $ext"
      # 在容器内以 coder 用户执行安装（容器内 code-server CLI）
      docker exec -u coder "$CONTAINER_NAME" sh -c "code-server --install-extension $ext" || {
        echo "[WARN] 容器内安装扩展 $ext 失败，稍后可在网页中重试"
      }
    fi
  done < "$INSTALLED_EXTENSIONS_FILE"
fi

# ----------------------------
# 7. 更新 Cloudflare Tunnel 配置
# ----------------------------
if [ ! -f "$TUNNEL_ID_FILE" ]; then
  echo "[ERROR] Cloudflared 隧道凭证文件不存在: $TUNNEL_ID_FILE"
  echo "请先在该机器上执行: cloudflared tunnel create <name> 并确保 $TUNNEL_ID_FILE 可见"
  exit 1
fi

echo "[INFO] 写入 Cloudflare Tunnel 配置到 $CONFIG_FILE ..."
sudo bash -c "cat > $CONFIG_FILE" <<EOF
tunnel: $(basename "$TUNNEL_ID_FILE" .json)
credentials-file: $TUNNEL_ID_FILE

ingress:
  - hostname: $DOMAIN_NAME
    service: http://localhost:$HOST_PORT
  - service: http_status:404
EOF

# ----------------------------
# 8. 重启 cloudflared 服务（若存在）
# ----------------------------
if systemctl list-units --full -all | grep -q cloudflared.service; then
  echo "[INFO] 重启 cloudflared 服务..."
  sudo systemctl restart cloudflared || true
  sudo systemctl enable cloudflared || true
else
  echo "[WARN] cloudflared systemd 服务未找到，请手动启动隧道: cloudflared tunnel run <tunnel-name>"
fi

# ----------------------------
# 9. 健康检查 (公网域名) 与自愈守护
# ----------------------------
echo "[INFO] 启动公网域名健康检查守护: https://$DOMAIN_NAME (间隔 ${HEALTH_CHECK_INTERVAL}s, 失败阈值 ${HEALTH_CHECK_RETRIES})"
(
  FAIL_COUNT=0
  while true; do
    # 使用 -k 忽略证书错误（Cloudflare TLS 通常正常），超时时间
    HTTP_CODE=$(curl -k --max-time "$HEALTH_CHECK_TIMEOUT" -s -o /dev/null -w "%{http_code}" "https://$DOMAIN_NAME" || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
      if [ "$FAIL_COUNT" -ne 0 ]; then
        echo "[INFO] 健康检查恢复: HTTP $HTTP_CODE"
      fi
      FAIL_COUNT=0
    else
      FAIL_COUNT=$((FAIL_COUNT+1))
      echo "[WARN] 健康检查: HTTP $HTTP_CODE (失败 $FAIL_COUNT/$HEALTH_CHECK_RETRIES)"
    fi

    if [ "$FAIL_COUNT" -ge "$HEALTH_CHECK_RETRIES" ]; then
      echo "[ERROR] 公网健康检查连续 $HEALTH_CHECK_RETRIES 次失败，尝试重启容器 $CONTAINER_NAME ..."
      docker restart "$CONTAINER_NAME" || echo "[ERROR] 重启容器失败"
      # 给容器一点时间恢复
      sleep 5
      FAIL_COUNT=0
    fi

    sleep "$HEALTH_CHECK_INTERVAL"
  done
) &

# ----------------------------
# 10. 最终输出
# ----------------------------
echo "========================================="
echo "✅ code-server 部署/升级完成!"
echo "容器名称: $CONTAINER_NAME"
echo "项目目录: $PROJECT_DIR"
echo "配置目录: $CONFIG_DIR"
echo "备份目录: ${BACKUP_DIR:-<none>}"
echo "访问 (公网): https://$DOMAIN_NAME"
echo "访问 (直连): http://<VPS-IP>:$HOST_PORT"
echo "提示: 若无法通过域名访问，请检查 Cloudflare DNS 记录和 cloudflared 日志"
echo "========================================="

