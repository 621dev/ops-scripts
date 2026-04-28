#!/bin/bash
# =============================================================================
# setup/deploy.sh  v4
# 초기 환경 구성 및 remote-agent 배포
#
# 변경 내용 (v4):
#   - Nginx 프록시 설정 파일(nginx_proxy.conf) 배포 안내 추가
#   - 네트워크 분리 환경 확인 단계 추가
#   - 터널 사전 테스트 단계 추가
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../monitoring-server/common/inventory.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log_ok()   { echo -e "  ${GREEN}[OK]${NC}    $1"; }
log_warn() { echo -e "  ${YELLOW}[WARN]${NC}  $1"; }
log_fail() { echo -e "  ${RED}[FAIL]${NC}  $1"; }
log_info() { echo -e "  ${BLUE}[INFO]${NC}  $1"; }
log_step() { echo ""; echo -e "${BOLD}${BLUE}STEP $1. $2${NC}"; echo "$(printf '─%.0s' {1..55})"; }

echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║   모니터링 서버 초기 배포 스크립트 v4                ║${NC}"
echo -e "${BOLD}${BLUE}║   네트워크 분리 환경 (SSH 터널 + Nginx 프록시)       ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════╝${NC}"

# ── STEP 1: SSH 키 생성 ──────────────────────────────────────────────────
log_step 1 "SSH 키 생성"
if [[ -f "$SSH_KEY" ]]; then
  log_warn "SSH 키 이미 존재: $SSH_KEY (건너뜀)"
else
  ssh-keygen -t rsa -b 4096 -f "$SSH_KEY" -N "" -C "ops-monitor@$(hostname)" 2>/dev/null
  log_ok "SSH 키 생성 완료: $SSH_KEY"
fi
PUB_KEY=$(cat "${SSH_KEY}.pub" 2>/dev/null)
log_info "공개키: ${PUB_KEY:0:60}..."

# ── STEP 2: 공개키 배포 안내 ─────────────────────────────────────────────
log_step 2 "공개키 배포 — 각 대상 서버에서 수동 실행"
echo ""
echo -e "  ${YELLOW}아래 명령을 각 대상 서버(총 8대)에서 실행하세요.${NC}"
echo ""

for SERVER in "${ALL_SERVERS[@]}"; do
  HOST=$(get_host "$SERVER"); PORT=$(get_port "$SERVER"); ALIAS=$(get_alias "$SERVER")
  echo -e "  ${BOLD}[$ALIAS] $HOST${NC}"
  cat << CMD
    sudo useradd -m -s /bin/bash ${SSH_USER} 2>/dev/null || true
    sudo mkdir -p /home/${SSH_USER}/.ssh
    echo '${PUB_KEY}' | sudo tee -a /home/${SSH_USER}/.ssh/authorized_keys
    sudo chown -R ${SSH_USER}:${SSH_USER} /home/${SSH_USER}/.ssh
    sudo chmod 700 /home/${SSH_USER}/.ssh && sudo chmod 600 /home/${SSH_USER}/.ssh/authorized_keys
    # journalctl 권한
    echo '${SSH_USER} ALL=(ALL) NOPASSWD: /bin/journalctl,/usr/bin/journalctl' \
      | sudo tee /etc/sudoers.d/ops-monitor
CMD
  echo ""
done

read -r -p "  공개키 배포 완료 후 Enter를 누르세요: " _

# ── STEP 3: SSH 접속 테스트 ──────────────────────────────────────────────
log_step 3 "SSH 접속 테스트"
SSH_FAIL=0
for SERVER in "${ALL_SERVERS[@]}"; do
  ALIAS=$(get_alias "$SERVER")
  if ssh_reachable "$SERVER"; then
    log_ok "[$ALIAS] SSH 접속 성공"
  else
    log_fail "[$ALIAS] SSH 접속 실패"
    SSH_FAIL=$((SSH_FAIL + 1))
  fi
done
if [[ $SSH_FAIL -gt 0 ]]; then
  echo ""
  log_warn "${SSH_FAIL}개 서버 접속 실패. 공개키 배포 상태를 재확인하세요."
  read -r -p "  계속 진행하시겠습니까? (y/N): " CONFIRM
  [[ "${CONFIRM,,}" != "y" ]] && exit 1
fi

# ── STEP 4: remote-agent 배포 ────────────────────────────────────────────
log_step 4 "remote-agent 배포 (local_check.sh → 각 서버)"
AGENT_SRC="$SCRIPT_DIR/../remote-agent/local_check.sh"

for SERVER in "${ALL_SERVERS[@]}"; do
  HOST=$(get_host "$SERVER"); PORT=$(get_port "$SERVER"); ALIAS=$(get_alias "$SERVER")
  ssh_reachable "$SERVER" || { log_warn "[$ALIAS] SSH 불가, 건너뜀"; continue; }

  # 원격 디렉토리 생성
  ssh $SSH_OPTS -p "$PORT" "${SSH_USER}@${HOST}" "mkdir -p $REMOTE_AGENT_DIR" 2>/dev/null

  # 스크립트 업로드 후 실행 권한 부여
  if scp -q $SSH_OPTS -P "$PORT" "$AGENT_SRC" "${SSH_USER}@${HOST}:${REMOTE_AGENT_SCRIPT}" 2>/dev/null; then
    ssh $SSH_OPTS -p "$PORT" "${SSH_USER}@${HOST}" "chmod +x $REMOTE_AGENT_SCRIPT" 2>/dev/null
    log_ok "[$ALIAS] 배포 완료"
  else
    log_fail "[$ALIAS] SCP 실패"
  fi
done

# ── STEP 5: Nginx 프록시 설정 배포 안내 ─────────────────────────────────
log_step 5 "Nginx 프록시 설정 (운영망 Nginx 서버에서 수동 적용)"
NGINX_HOST_ADDR=$(get_host "${NGINX_SERVERS[0]}")
echo ""
echo -e "  ${YELLOW}아래 설정을 운영망 Nginx 서버($NGINX_HOST_ADDR)에 적용하세요.${NC}"
echo ""
cat << 'NGINXGUIDE'
  # 1. 프록시 설정 파일 복사
  scp setup/nginx_proxy.conf ops@192.168.10.10:/tmp/ops_proxy.conf
  sudo cp /tmp/ops_proxy.conf /etc/nginx/conf.d/ops_proxy.conf

  # 2. nginx_proxy.conf 에서 모니터링 서버 IP 수정 (10.0.0.100 → 실제 IP)
  sudo sed -i 's/10.0.0.100/실제_모니터링_서버_IP/g' /etc/nginx/conf.d/ops_proxy.conf

  # 3. 문법 검사 및 reload
  sudo nginx -t && sudo nginx -s reload
NGINXGUIDE

# ── STEP 6: SSH 터널 테스트 ──────────────────────────────────────────────
log_step 6 "SSH 터널 테스트 (Redis / MySQL)"
echo ""
log_info "Redis 터널 오픈 중..."
open_tunnels redis
sleep 1

TUNNEL_FAIL=0
for entry in "${REDIS_TUNNEL_MAP[@]}"; do
  IFS=':' read -r _ _ alias _ _ local_port <<< "$entry"
  if check_tunnel_alive "$local_port" "redis[$alias]"; then
    log_ok "Redis 터널 [$alias] → 127.0.0.1:${local_port}"
    # redis-cli 로 실제 PING 확인
    PONG=$(redis-cli -h 127.0.0.1 -p "$local_port" PING 2>/dev/null || true)
    [[ "$PONG" == "PONG" ]] && log_ok "  redis-cli PING → PONG" \
                             || log_warn "  redis-cli PING 실패 (AUTH 또는 Redis 미기동?)"
  else
    log_fail "Redis 터널 [$alias] 응답 없음"
    TUNNEL_FAIL=$((TUNNEL_FAIL + 1))
  fi
done

echo ""
log_info "MySQL 터널 오픈 중..."
open_tunnels mysql
sleep 1

for entry in "${MYSQL_TUNNEL_MAP[@]}"; do
  IFS=':' read -r _ _ alias _ _ local_port <<< "$entry"
  if check_tunnel_alive "$local_port" "mysql[$alias]"; then
    log_ok "MySQL 터널 [$alias] → 127.0.0.1:${local_port}"
    # mysql 로 실제 접속 확인
    RESULT=$(mysql -u "$MYSQL_USER" -h 127.0.0.1 -P "$local_port" \
      --connect-timeout=3 -sNe "SELECT 1;" 2>/dev/null || true)
    [[ "$RESULT" == "1" ]] && log_ok "  mysql 접속 → SELECT 1 정상" \
                            || log_warn "  mysql 접속 실패 (계정/비밀번호 확인 필요)"
  else
    log_fail "MySQL 터널 [$alias] 응답 없음"
    TUNNEL_FAIL=$((TUNNEL_FAIL + 1))
  fi
done

# 터널 정리
close_tunnels all

# ── STEP 7: Actuator 프록시 테스트 ──────────────────────────────────────
log_step 7 "Actuator Nginx 프록시 테스트"
echo ""
for url in "${SPRING_ACTUATOR_URLS[@]}"; do
  HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "${url}/health" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "200" ]]; then
    log_ok "Actuator 프록시: $url/health → HTTP $HTTP_CODE"
  elif [[ "$HTTP_CODE" == "403" ]]; then
    log_warn "Actuator 프록시: $url/health → HTTP 403 (모니터링 서버 IP 허용 여부 확인)"
  elif [[ "$HTTP_CODE" == "000" ]]; then
    log_fail "Actuator 프록시: $url/health → 응답 없음 (Nginx 프록시 설정 확인)"
  else
    log_warn "Actuator 프록시: $url/health → HTTP $HTTP_CODE"
  fi
done

# ── 최종 결과 ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}$(printf '═%.0s' {1..55})${NC}"
if [[ $SSH_FAIL -eq 0 && $TUNNEL_FAIL -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}✔ 배포 완료. 모든 서버 접속 및 터널 정상${NC}"
else
  echo -e "${YELLOW}${BOLD}⚠ 일부 항목 실패 (SSH: ${SSH_FAIL}건, 터널: ${TUNNEL_FAIL}건)${NC}"
fi
echo ""
echo -e "${BOLD}다음 단계:${NC}"
echo "  1. inventory.sh 에서 실제 IP 확인"
echo "  2. nginx_proxy.conf 의 모니터링 서버 IP 수정 및 적용"
echo "  3. 점검 실행:"
echo "     bash monitoring-server/run_all_checks.sh"
echo "  4. Cron 등록:"
echo "     30 8 * * * /opt/check-scripts-v4/monitoring-server/overnight_check.sh"
echo ""
