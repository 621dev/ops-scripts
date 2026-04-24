#!/bin/bash
# =============================================================================
# monitoring-server/common/inventory.sh  v4
# conf 파일 로더 + SSH/터널 헬퍼 함수
#
# 설정값은 이 파일이 아닌 conf/ 에서 관리합니다.
#   conf/servers.conf     → 서버 IP, SSH, 터널, 프록시 URL
#   conf/thresholds.conf  → 임계값, 큐 키, 튜닝값
# =============================================================================

INVENTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="$(cd "${INVENTORY_DIR}/../../conf" && pwd)"

# conf 파일 로드
_load_conf() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "[ERROR] conf 파일 없음: $f" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$f"
}

_load_conf "${CONF_DIR}/servers.conf"
_load_conf "${CONF_DIR}/thresholds.conf"

# conf 로드 후 ALL_SERVERS 조합 (servers.conf 에서 배열 조각 조합)
ALL_SERVERS=(
  "${NGINX_SERVERS[@]}"
  "${SPRING_SERVERS[@]}"
  "${REDIS_SERVERS[@]}"
  "${MYSQL_SERVERS[@]}"
)

# SSH_OPTS 조합 (SSH_USER, SSH_KEY 로드 후)
SSH_OPTS="-o StrictHostKeyChecking=no \
          -o ConnectTimeout=10 \
          -o BatchMode=yes \
          -o ServerAliveInterval=10 \
          -i ${SSH_KEY}"

# =============================================================================
# 헬퍼 함수
# =============================================================================
get_host()  { echo "${1%%:*}"; }
get_port()  { echo "${1}" | cut -d: -f2; }
get_alias() { echo "${1##*:}"; }

timeout_cmd() {
  local secs="$1"; shift
  command -v timeout &>/dev/null && timeout "$secs" "$@" || "$@"
}

ssh_run() {
  local server="$1"; shift
  ssh $SSH_OPTS -p "$(get_port "$server")" "${SSH_USER}@$(get_host "$server")" "$@" 2>/dev/null
}

ssh_run_script() {
  local server="$1" script="$2"; shift 2
  ssh $SSH_OPTS -p "$(get_port "$server")" \
    "${SSH_USER}@$(get_host "$server")" "bash ${script} $*" 2>/dev/null
}

ssh_reachable() {
  local server="$1"
  ssh $SSH_OPTS -p "$(get_port "$server")" -o ConnectTimeout=5 \
    "${SSH_USER}@$(get_host "$server")" "echo ok" 2>/dev/null | grep -q "ok"
}

# =============================================================================
# SSH 터널 관리
# =============================================================================
_open_tunnel() {
  local entry="$1"
  local remote_host ssh_port alias tunnel_host remote_port local_port
  IFS=':' read -r remote_host ssh_port alias tunnel_host remote_port local_port <<< "$entry"

  mkdir -p "$TUNNEL_PID_DIR"
  local pid_file="${TUNNEL_PID_DIR}/${alias}_${local_port}.pid"

  if [[ -f "$pid_file" ]]; then
    local old_pid; old_pid=$(cat "$pid_file")
    kill -0 "$old_pid" 2>/dev/null && return 0
    rm -f "$pid_file"
  fi

  ssh $SSH_OPTS -p "$ssh_port" \
    -L "${local_port}:${tunnel_host}:${remote_port}" \
    -N -f "${SSH_USER}@${remote_host}" 2>/dev/null || return 1

  local tunnel_pid
  tunnel_pid=$(pgrep -f "ssh.*${local_port}:${tunnel_host}:${remote_port}.*${remote_host}" | head -1)
  [[ -n "$tunnel_pid" ]] && echo "$tunnel_pid" > "$pid_file"
  return 0
}

open_tunnels() {
  local target="${1:-all}"
  local failed=0

  if [[ "$target" == "all" || "$target" == "redis" ]]; then
    for entry in "${REDIS_TUNNEL_MAP[@]}"; do
      IFS=':' read -r _ _ alias _ local_port <<< "$entry"
      if _open_tunnel "$entry"; then
        echo -e "  \033[0;32m[OK]\033[0m    터널: redis[$alias] → 127.0.0.1:${local_port}"
      else
        echo -e "  \033[0;31m[FAIL]\033[0m  터널 실패: redis[$alias]"
        failed=$((failed + 1))
      fi
    done
  fi

  if [[ "$target" == "all" || "$target" == "mysql" ]]; then
    for entry in "${MYSQL_TUNNEL_MAP[@]}"; do
      IFS=':' read -r _ _ alias _ local_port <<< "$entry"
      if _open_tunnel "$entry"; then
        echo -e "  \033[0;32m[OK]\033[0m    터널: mysql[$alias] → 127.0.0.1:${local_port}"
      else
        echo -e "  \033[0;31m[FAIL]\033[0m  터널 실패: mysql[$alias]"
        failed=$((failed + 1))
      fi
    done
  fi

  sleep 1
  return $failed
}

close_tunnels() {
  local target="${1:-all}"
  [[ ! -d "$TUNNEL_PID_DIR" ]] && return 0
  local closed=0

  for pid_file in "${TUNNEL_PID_DIR}"/*.pid; do
    [[ -f "$pid_file" ]] || continue
    local fname; fname=$(basename "$pid_file")
    [[ "$target" == "redis" ]] && ! echo "$fname" | grep -q "redis" && continue
    [[ "$target" == "mysql" ]] && ! echo "$fname" | grep -q "mysql" && continue

    local pid; pid=$(cat "$pid_file" 2>/dev/null)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null && closed=$((closed + 1))
    fi
    rm -f "$pid_file"
  done

  [[ $closed -gt 0 ]] && echo -e "  \033[0;32m[OK]\033[0m    SSH 터널 ${closed}개 종료"
}

check_tunnel_alive() {
  local local_port="$1" label="${2:-tunnel}"
  timeout_cmd 3 bash -c "echo >/dev/tcp/127.0.0.1/$local_port" 2>/dev/null && return 0
  echo -e "  \033[1;33m[WARN]\033[0m  터널 응답 없음: 127.0.0.1:${local_port} ($label)"
  return 1
}
