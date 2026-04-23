#!/bin/bash
# =============================================================================
# common/utils.sh  v2 — 공통 유틸리티
# 변경 이력:
#   v2 - set -e 환경에서 ((n++)) 가 0→1 일 때 exit 1 버그 수정 → n=$((n+1))
#      - check_threshold: 빈값 전달 시 awk 크래시 → 기본값 0 처리
#      - check_service: 2>/dev/null 위치 수정, 반환값 보호
#      - require_cmd: 의존 툴 사전 확인 헬퍼 추가
#      - is_number: 숫자 여부 검증 헬퍼 추가
#      - timeout_cmd: 타임아웃 래퍼 추가
# =============================================================================

# ── Bash 버전 최소 요구 ────────────────────────────────────────────────────
if (( BASH_VERSINFO[0] < 4 )); then
  echo "[ERROR] bash 4.0 이상 필요 (현재: $BASH_VERSION)" >&2
  exit 1
fi

# ── 색상 (TTY 아닌 경우 비활성) ───────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

# ── 로그 설정 ─────────────────────────────────────────────────────────────
LOG_DIR="${OPS_LOG_DIR:-/var/log/ops-check}"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
DATE_LABEL=$(date '+%Y-%m-%d %H:%M:%S')
LOG_FILE=""

init_log() {
  local script_name="$1"
  mkdir -p "$LOG_DIR" 2>/dev/null || {
    LOG_DIR="/tmp/ops-check"
    mkdir -p "$LOG_DIR"
    echo "[WARN] $LOG_DIR 생성 실패, /tmp/ops-check 로 대체"
  }
  LOG_FILE="${LOG_DIR}/${script_name}_${TIMESTAMP}.log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "로그 파일: $LOG_FILE"
}

# ── 출력 헬퍼 ─────────────────────────────────────────────────────────────
print_header() {
  local title="$1"
  echo ""
  echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
  printf "${BOLD}${BLUE}║  %-60s║${NC}\n" "$title"
  echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

print_section() {
  echo ""
  echo -e "${BOLD}${CYAN}▶ $1${NC}"
  echo -e "${CYAN}$(printf '─%.0s' {1..60})${NC}"
}

print_ok()   { echo -e "  ${GREEN}[OK]${NC}    $1"; }
print_warn() { echo -e "  ${YELLOW}[WARN]${NC}  $1"; }
print_fail() { echo -e "  ${RED}[FAIL]${NC}  $1"; }
print_info() { echo -e "  ${BLUE}[INFO]${NC}  $1"; }

# ── 결과 집계 ─────────────────────────────────────────────────────────────
# [수정] ((n++)) 는 n=0→1 시 종료코드 1 → set -e 환경에서 스크립트 종료됨
# n=$((n+1)) 로 교체하여 set -e 안전하게 처리
RESULT_OK=0
RESULT_WARN=0
RESULT_FAIL=0

record_ok()   { RESULT_OK=$((RESULT_OK+1));     print_ok   "$1"; }
record_warn() { RESULT_WARN=$((RESULT_WARN+1)); print_warn "$1"; }
record_fail() { RESULT_FAIL=$((RESULT_FAIL+1)); print_fail "$1"; }

print_summary() {
  local total=$((RESULT_OK + RESULT_WARN + RESULT_FAIL))
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━ 점검 요약 (총 ${total}건) ━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  ${GREEN}정상${NC}   : $RESULT_OK"
  echo -e "  ${YELLOW}경고${NC}   : $RESULT_WARN"
  echo -e "  ${RED}장애${NC}   : $RESULT_FAIL"
  echo ""
  if   [[ $RESULT_FAIL -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}▶ 최종 상태: 장애 발생 — 즉시 조치 필요${NC}"
  elif [[ $RESULT_WARN -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}▶ 최종 상태: 경고 — 모니터링 권장${NC}"
  else
    echo -e "  ${GREEN}${BOLD}▶ 최종 상태: 정상${NC}"
  fi
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  [[ $RESULT_FAIL -gt 0 ]] && return 2
  [[ $RESULT_WARN -gt 0 ]] && return 1
  return 0
}

# ── 숫자 검증 헬퍼 ────────────────────────────────────────────────────────
# [신규] 빈값·비숫자 입력에서 awk 크래시 방지
is_number() { [[ "${1:-}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }

# ── 임계값 비교 ─────────────────────────────────────────────────────────
# [수정] 빈값 전달 시 val=0 으로 처리, 숫자 검증 추가
check_threshold() {
  local val="${1:-0}" warn="$2" fail="$3" label="$4" unit="${5:-%}"
  is_number "$val" || val=0
  if   awk "BEGIN{exit !($val >= $fail)}"; then
    record_fail "$label: ${val}${unit} (fail≥${fail}${unit})"
  elif awk "BEGIN{exit !($val >= $warn)}"; then
    record_warn "$label: ${val}${unit} (warn≥${warn}${unit})"
  else
    record_ok   "$label: ${val}${unit}"
  fi
}

# ── 의존 명령 확인 ────────────────────────────────────────────────────────
# [신규] 스크립트 시작 전 필수 툴 존재 확인
require_cmd() {
  local missing=()
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    print_warn "필수 명령어 없음: ${missing[*]} — 관련 점검 항목 건너뜀"
    return 1
  fi
  return 0
}

# ── 타임아웃 래퍼 ─────────────────────────────────────────────────────────
# [신규] timeout 명령어 없는 환경 호환
timeout_cmd() {
  local secs="$1"; shift
  if command -v timeout &>/dev/null; then
    timeout "$secs" "$@"
  else
    "$@"
  fi
}

# ── 포트 연결 확인 ─────────────────────────────────────────────────────────
check_port() {
  local host="$1" port="$2" label="$3"
  if timeout_cmd 3 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
    record_ok "$label (${host}:${port}) 연결 가능"
  else
    record_fail "$label (${host}:${port}) 연결 불가"
  fi
}

# ── 프로세스 확인 ─────────────────────────────────────────────────────────
check_process() {
  local pattern="$1" label="$2"
  local pid
  pid=$(pgrep -f "$pattern" 2>/dev/null | head -1)
  if [[ -n "$pid" ]]; then
    record_ok "$label 실행 중 (PID: $pid)"
  else
    record_fail "$label 프로세스 없음"
  fi
}

# ── systemd 서비스 확인 ────────────────────────────────────────────────────
# [수정] check_service "mysql" 2>/dev/null 처럼 외부에서 리다이렉트 못 막는 구조 수정
check_service() {
  local svc="$1"
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    record_ok "서비스 [$svc] active"
    return 0
  else
    record_fail "서비스 [$svc] inactive/dead"
    return 1
  fi
}

# ── 디스크 사용률 ─────────────────────────────────────────────────────────
check_disk() {
  local path="${1:-/}" warn="${2:-70}" fail="${3:-85}"
  if [[ ! -e "$path" ]]; then
    record_warn "디스크 경로 없음: $path"
    return
  fi
  local usage
  usage=$(df "$path" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
  check_threshold "${usage:-0}" "$warn" "$fail" "디스크 ($path)" "%"
}

# ── CPU Load (1분 loadavg) ────────────────────────────────────────────────
check_cpu_load() {
  local warn="${1:-70}" fail="${2:-90}"
  local cores load1 pct
  cores=$(nproc 2>/dev/null || echo 1)
  load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
  pct=$(awk "BEGIN{printf \"%.0f\", ($load1/$cores)*100}")
  check_threshold "$pct" "$warn" "$fail" "CPU Load 1m (${load1}, ${cores}코어)" "%"
}

# ── 메모리 사용률 ─────────────────────────────────────────────────────────
check_memory() {
  local warn="${1:-75}" fail="${2:-90}"
  local total used pct
  # [수정] free -m 출력에서 available 기반으로 실질 사용률 계산
  read -r total used available <<< "$(free -m 2>/dev/null | awk 'NR==2{print $2,$3,$7}')"
  total="${total:-1}"; used="${used:-0}"
  pct=$(awk "BEGIN{printf \"%.0f\", ($used/$total)*100}")
  check_threshold "$pct" "$warn" "$fail" "메모리 사용률 (${used}MB/${total}MB)" "%"
}

# ── 커널 오류 확인 ─────────────────────────────────────────────────────────
check_kernel_errors() {
  local minutes="${1:-60}"
  require_cmd journalctl || return
  local errors
  errors=$(journalctl -k --since "-${minutes}min" -p err..emerg --no-pager 2>/dev/null | grep -c . || true)
  if [[ "${errors:-0}" -gt 0 ]]; then
    record_warn "커널 오류 ${errors}건 (최근 ${minutes}분)"
    journalctl -k --since "-${minutes}min" -p err..emerg --no-pager 2>/dev/null \
      | tail -5 | while IFS= read -r line; do print_info "  $line"; done
  else
    record_ok "커널 오류 없음 (최근 ${minutes}분)"
  fi
}

# ── HTTP 헬스체크 ─────────────────────────────────────────────────────────
check_http() {
  local url="$1" label="$2" expect_code="${3:-200}"
  require_cmd curl || return
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
  if [[ "$http_code" == "$expect_code" ]]; then
    record_ok "$label → HTTP $http_code"
  else
    record_fail "$label → HTTP $http_code (기대: $expect_code) — $url"
  fi
}

# ── JSON 파싱 (jq 우선, python3 fallback) ────────────────────────────────
# [신규] python3 단독 의존 제거
json_get() {
  local json="$1" key="$2"
  if command -v jq &>/dev/null; then
    echo "$json" | jq -r "$key" 2>/dev/null
  elif command -v python3 &>/dev/null; then
    echo "$json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    keys = '$key'.strip('.').split('.')
    for k in keys:
        d = d[k] if isinstance(d, dict) else d
    print(d)
except: print('N/A')
" 2>/dev/null
  else
    echo "$json" | grep -o "\"${key##*.}\":\"[^\"]*\"" | head -1 | cut -d'"' -f4
  fi
}
