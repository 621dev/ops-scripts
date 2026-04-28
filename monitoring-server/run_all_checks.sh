#!/bin/bash
# =============================================================================
# monitoring-server/run_all_checks.sh  v4
#
# 변경 내용:
#   - 점검 시작 전 SSH 터널 오픈 (Redis/MySQL용)
#   - 점검 종료 후 터널 닫기 (trap으로 비정상 종료 시에도 보장)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/utils.sh"
source "$SCRIPT_DIR/common/inventory.sh"

TARGET_ROLE="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) TARGET_ROLE="$2"; shift 2 ;;
    --help) echo "사용법: $0 [--role nginx|springboot|redis|mysql|all]"; exit 0 ;;
    *) shift ;;
  esac
done

mkdir -p "$REPORT_DIR" 2>/dev/null || true

# ── 터널 정리: 정상/비정상 종료 모두 보장 ───────────────────────────────
trap 'close_tunnels all' EXIT INT TERM

# ── 역할별 필요한 터널만 오픈 ───────────────────────────────────────────
print_section "SSH 터널 준비"
case "$TARGET_ROLE" in
  redis)      open_tunnels redis ;;
  mysql)      open_tunnels mysql ;;
  springboot) : ;;   # Nginx 프록시 사용 — 터널 불필요
  nginx)      : ;;   # 직접 접근 — 터널 불필요
  all|*)      open_tunnels all ;;
esac

run_check() {
  local name="$1" script="$2"
  [[ ! -f "$script" ]] && { print_warn "$name 스크립트 없음: $script"; return; }
  echo ""
  echo -e "${BOLD}${BLUE}════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${BLUE}  ▶ 점검: $name${NC}"
  echo -e "${BOLD}${BLUE}════════════════════════════════════════════════${NC}"
  bash "$script"; local rc=$?
  echo -e "${BOLD}  [ 완료: $name | 종료코드: $rc ]${NC}"
}

print_header "인프라 통합 점검 | $DATE_LABEL (대상: $TARGET_ROLE)"

CHECK_DIR="$SCRIPT_DIR/checks"
case "$TARGET_ROLE" in
  nginx)      run_check "Nginx"       "$CHECK_DIR/check_nginx.sh" ;;
  springboot) run_check "Spring Boot" "$CHECK_DIR/check_springboot.sh" ;;
  redis)      run_check "Redis"       "$CHECK_DIR/check_redis_cluster.sh" ;;
  mysql)      run_check "MySQL"       "$CHECK_DIR/check_mysql_repl.sh" ;;
  all|*)
    run_check "Nginx"       "$CHECK_DIR/check_nginx.sh"
    run_check "Spring Boot" "$CHECK_DIR/check_springboot.sh"
    run_check "Redis"       "$CHECK_DIR/check_redis_cluster.sh"
    run_check "MySQL"       "$CHECK_DIR/check_mysql_repl.sh"
    ;;
esac

echo ""
echo -e "${GREEN}${BOLD}✔ 점검 완료. 로그: $MONITOR_LOG_DIR${NC}"

# ── 로그 분리 저장 ────────────────────────────────────────────────────────────
DAILY_DIR="${MONITOR_LOG_DIR}/daily"
ALERT_DIR="${MONITOR_LOG_DIR}/alerts"
mkdir -p "$DAILY_DIR" "$ALERT_DIR"

TODAY=$(date '+%Y%m%d')
NOW=$(date '+%Y-%m-%d %H:%M:%S')
DAILY_LOG="${DAILY_DIR}/${TODAY}.log"
ALERT_LOG="${ALERT_DIR}/${TODAY}_alerts.log"

# 최신 로그 파일에서 한 줄 포맷으로 변환
LATEST_LOG=$(ls -t "${MONITOR_LOG_DIR}"/*.log 2>/dev/null | head -1)

if [[ -n "$LATEST_LOG" ]]; then
  # [시간] [위험도] [내용] 형식으로 변환
  grep -E "\[OK\]|\[WARN\]|\[FAIL\]|\[INFO\]" "$LATEST_LOG" \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | sed -E "s/[[:space:]]*\[OK\][[:space:]]*/[${NOW}] [OK]    /g" \
    | sed -E "s/[[:space:]]*\[WARN\][[:space:]]*/[${NOW}] [WARN]  /g" \
    | sed -E "s/[[:space:]]*\[FAIL\][[:space:]]*/[${NOW}] [FAIL]  /g" \
    | sed -E "s/[[:space:]]*\[INFO\][[:space:]]*/[${NOW}] [INFO]  /g" \
    >> "$DAILY_LOG"

  # 구분선 추가
  echo "── 점검 완료: ${NOW}  대상: ${TARGET_ROLE}  FAIL:${RESULT_FAIL}건  WARN:${RESULT_WARN}건  OK:${RESULT_OK}건" \
    >> "$DAILY_LOG"

  # FAIL/WARN 만 alerts 로그에 저장
  if [[ $RESULT_FAIL -gt 0 || $RESULT_WARN -gt 0 ]]; then
    grep -E "\[OK\]|\[WARN\]|\[FAIL\]" "$LATEST_LOG" \
      | grep -E "\[WARN\]|\[FAIL\]" \
      | sed 's/\x1b\[[0-9;]*m//g' \
      | sed -E "s/[[:space:]]*\[WARN\][[:space:]]*/[${NOW}] [WARN]  /g" \
      | sed -E "s/[[:space:]]*\[FAIL\][[:space:]]*/[${NOW}] [FAIL]  /g" \
      >> "$ALERT_LOG"
    echo "── ${NOW}  FAIL:${RESULT_FAIL}건  WARN:${RESULT_WARN}건" >> "$ALERT_LOG"
  fi
fi

# trap에 의해 close_tunnels 자동 실행
