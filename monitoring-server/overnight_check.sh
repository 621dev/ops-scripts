#!/bin/bash
# =============================================================================
# monitoring-server/overnight_check.sh
# 야간 시간대(18:00~08:30) 통합 분석 — 모니터링 서버 단독 실행
#
# 점검 방식:
#   [SSH]    각 서버 로컬 로그 → 모니터링 서버로 수집 후 분석
#   [직접]   Redis CLUSTER INFO / INFO all
#   [직접]   MySQL SHOW REPLICA STATUS, InnoDB 통계
#   [직접]   Actuator /health
#   [직접]   journalctl (각 서버 SSH로 조회)
#
# 사용법:
#   ./overnight_check.sh [--date YYYY-MM-DD] [--role all|nginx|springboot|redis|mysql|system]
#                        [--start HH:MM] [--end HH:MM] [--output DIR] [--help]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/utils.sh"
source "$SCRIPT_DIR/common/inventory.sh"

# ── 인자 파싱 ─────────────────────────────────────────────────────────────
TARGET_ROLE="all"
CUSTOM_DATE=""
NIGHT_START_TIME="${OVERNIGHT_START:-18:00}"   # thresholds.conf 에서 기본값 로드
NIGHT_END_TIME="${OVERNIGHT_END:-08:30}"
OUTPUT_DIR="$OVERNIGHT_DIR"

usage() {
  cat <<EOF
사용법: $0 [옵션]
  --date   YYYY-MM-DD   분석 기준 날짜 야간 (기본: 어제)
  --role   ROLE         분석 역할 (nginx|springboot|redis|mysql|system|all)
  --start  HH:MM        야간 시작 시각 (기본: 18:00)
  --end    HH:MM        야간 종료 시각 (기본: 08:30)
  --output DIR          리포트 저장 경로
  --help                도움말
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --date)   CUSTOM_DATE="$2";      shift 2 ;;
    --role)   TARGET_ROLE="$2";      shift 2 ;;
    --start)  NIGHT_START_TIME="$2"; shift 2 ;;
    --end)    NIGHT_END_TIME="$2";   shift 2 ;;
    --output) OUTPUT_DIR="$2";       shift 2 ;;
    --help|-h) usage ;;
    *) shift ;;
  esac
done

# ── 시간 범위 계산 ────────────────────────────────────────────────────────
if [[ -n "$CUSTOM_DATE" ]]; then
  NIGHT_START="${CUSTOM_DATE} ${NIGHT_START_TIME}:00"
  NEXT_DAY=$(date -d "${CUSTOM_DATE} +1 day" '+%Y-%m-%d' 2>/dev/null)
  NIGHT_END="${NEXT_DAY} ${NIGHT_END_TIME}:00"
else
  TODAY=$(date '+%Y-%m-%d')
  YESTERDAY=$(date -d 'yesterday' '+%Y-%m-%d' 2>/dev/null)
  NIGHT_START="${YESTERDAY} ${NIGHT_START_TIME}:00"
  NIGHT_END="${TODAY} ${NIGHT_END_TIME}:00"
fi
NIGHT_START_EPOCH=$(date -d "$NIGHT_START" +%s 2>/dev/null || echo 0)
NIGHT_END_EPOCH=$(date   -d "$NIGHT_END"   +%s 2>/dev/null || echo 0)
NIGHT_DURATION_H=$(awk "BEGIN{printf \"%.1f\", ($NIGHT_END_EPOCH-$NIGHT_START_EPOCH)/3600}")

mkdir -p "$OUTPUT_DIR" 2>/dev/null || OUTPUT_DIR="/tmp/ops-check/overnight" && mkdir -p "$OUTPUT_DIR"
REPORT_FILE="${OUTPUT_DIR}/overnight_${TIMESTAMP}.txt"
LATEST_LINK="${OUTPUT_DIR}/latest.txt"
exec > >(tee -a "$REPORT_FILE") 2>&1

# ── SSH 터널 준비 (Redis/MySQL 직접 접근 불가 → 터널 경유) ──────────────
# 비정상 종료 시에도 터널이 반드시 닫히도록 trap 등록
trap 'close_tunnels all' EXIT INT TERM

echo ""
echo -e "  \033[1m[터널 준비]\033[0m  Redis / MySQL SSH 터널 오픈 중..."
case "$TARGET_ROLE" in
  redis)  open_tunnels redis ;;
  mysql)  open_tunnels mysql ;;
  nginx|springboot|system) : ;;   # 터널 불필요
  all|*)  open_tunnels all  ;;
esac

# ── awk 내부 epoch 계산 (fork 없는 고성능 파싱) ───────────────────────────
NIGHT_FILTER_AWK='
BEGIN {
  m["Jan"]=1;m["Feb"]=2;m["Mar"]=3;m["Apr"]=4;m["May"]=5;m["Jun"]=6
  m["Jul"]=7;m["Aug"]=8;m["Sep"]=9;m["Oct"]=10;m["Nov"]=11;m["Dec"]=12
}
function to_epoch(ts,   Y,M,D,h,mi,s,ep) {
  if (match(ts, /([0-9]{4})-([0-9]{2})-([0-9]{2})[ T]([0-9]{2}):([0-9]{2}):([0-9]{2})/, a))
    { Y=a[1]+0;M=a[2]+0;D=a[3]+0;h=a[4]+0;mi=a[5]+0;s=a[6]+0 }
  else if (match(ts, /([0-9]{2})\/([A-Za-z]{3})\/([0-9]{4}):([0-9]{2}):([0-9]{2}):([0-9]{2})/, a))
    { D=a[1]+0;M=m[a[2]];Y=a[3]+0;h=a[4]+0;mi=a[5]+0;s=a[6]+0 }
  else return -1
  if (M<3){Y--;M+=12}
  ep=int(365.25*(Y+4716))+int(30.6001*(M+1))+D-1524
  ep=(ep-2440588)*86400+h*3600+mi*60+s
  return ep
}
'

# SSH로 원격 로그를 수집하여 야간 구간 라인만 추출
# $1: 서버항목, $2: 원격 로그 경로, $3: 로그 형식 (iso|nginx_access|nginx_error)
ssh_extract_log() {
  local server="$1" remote_log="$2" fmt="${3:-iso}"
  local host port
  host=$(get_host "$server"); port=$(get_port "$server")

  # 원격에서 로그를 tail하여 모니터링 서버로 전송, awk로 야간 구간 필터
  ssh $SSH_OPTS -p "$port" "${SSH_USER}@${host}" \
    "tail -n 50000 '$remote_log' 2>/dev/null || true" 2>/dev/null | \
  awk -v s="$NIGHT_START_EPOCH" -v e="$NIGHT_END_EPOCH" \
    -v fmt="$fmt" "$NIGHT_FILTER_AWK"'
    {
      if (fmt == "nginx_access") {
        match($0, /\[([^\]]+)\]/, a); ts=a[1]
      } else if (fmt == "nginx_error") {
        match($0, /([0-9]{4}\/[0-9]{2}\/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})/, a)
        gsub("/","-",a[1]); ts=a[1]
      } else {
        match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}/, a); ts=a[0]
      }
      ep=to_epoch(ts)
      if (ep>=s && ep<=e) print
    }' 2>/dev/null
}

# SSH journalctl 조회
ssh_journalctl() {
  local server="$1"; shift
  local host port
  host=$(get_host "$server"); port=$(get_port "$server")
  ssh $SSH_OPTS -p "$port" "${SSH_USER}@${host}" \
    "journalctl --since='$NIGHT_START' --until='$NIGHT_END' --no-pager $* 2>/dev/null || true" 2>/dev/null
}

# Redis 래퍼
redis_cmd() {
  local node="$1"; shift
  local h p; IFS=':' read -r h p <<< "$node"
  if [[ -n "$REDIS_AUTH" ]]; then
    redis-cli -h "$h" -p "$p" --no-auth-warning -a "$REDIS_AUTH" "$@" 2>/dev/null || true
  else
    redis-cli -h "$h" -p "$p" "$@" 2>/dev/null || true
  fi
}

# MySQL 래퍼 — 터널 포트를 인자로 받도록 수정
# mysql_exec <host> <port> <query>
mysql_exec() {
  local host="$1" port="$2" q="$3"
  if [[ -f "$MYSQL_CNF" ]]; then
    mysql --defaults-file="$MYSQL_CNF" -h "$host" -P "$port" --connect-timeout=5 -sNe "$q" 2>/dev/null || true
  elif [[ -n "$MYSQL_PASS" ]]; then
    mysql -u "$MYSQL_USER" -p"$MYSQL_PASS" -h "$host" -P "$port" --connect-timeout=5 -sNe "$q" 2>/dev/null || true
  else
    mysql -u "$MYSQL_USER" -h "$host" -P "$port" --connect-timeout=5 -sNe "$q" 2>/dev/null || true
  fi
}

# 섹션 타이머
declare -A SECT_OK=() SECT_WARN=() SECT_FAIL=()
_PREV_OK=0; _PREV_WN=0; _PREV_FL=0; _SECT_TS=0
begin_sect() { _PREV_OK=$RESULT_OK; _PREV_WN=$RESULT_WARN; _PREV_FL=$RESULT_FAIL; _SECT_TS=$(date +%s); }
end_sect()   {
  local nm="$1" el=$(( $(date +%s) - _SECT_TS ))
  SECT_OK[$nm]=$(( RESULT_OK-_PREV_OK )); SECT_WARN[$nm]=$(( RESULT_WARN-_PREV_WN ))
  SECT_FAIL[$nm]=$(( RESULT_FAIL-_PREV_FL ))
  print_info "섹션 소요: ${el}초"
}

# ── 리포트 헤더 ───────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${BLUE}"
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║    야간 운영 점검 리포트 v4 — SSH 터널 + Nginx 프록시 경유         ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
printf "║  점검 구간: %-55s║\n" "$NIGHT_START  ~  $NIGHT_END"
printf "║  구간 길이: %-55s║\n" "${NIGHT_DURATION_H}시간"
printf "║  분석 대상: %-55s║\n" "$TARGET_ROLE"
printf "║  생성 시각: %-55s║\n" "$DATE_LABEL"
printf "║  리포트:    %-55s║\n" "$REPORT_FILE"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ═════════════════════════════════════════════════════════════════════════════
# A. 시스템 / 커널 — SSH journalctl
# ═════════════════════════════════════════════════════════════════════════════
if [[ "$TARGET_ROLE" == "all" || "$TARGET_ROLE" == "system" ]]; then
  print_section "A. 시스템 / 커널 이벤트 (전 서버 SSH)"
  begin_sect

  for SERVER in "${ALL_SERVERS[@]}"; do
    ALIAS=$(get_alias "$SERVER")
    ssh_reachable "$SERVER" || { record_warn "[$ALIAS] SSH 불가"; continue; }

    OOM=$(ssh_journalctl "$SERVER" "-k" | grep -c "Out of memory\|oom_kill_process" || true)
    KPANIC=$(ssh_journalctl "$SERVER" "-k" | grep -c "Kernel panic\|BUG:" || true)
    IO_ERR=$(ssh_journalctl "$SERVER" "-k" | grep -c "I/O error\|Buffer I/O error" || true)
    RESTARTS=$(ssh_journalctl "$SERVER" "" | grep -c "Started\|Restarted" || true)

    [[ "${OOM:-0}"    -gt 0 ]] && record_fail "[$ALIAS] OOM Killer: ${OOM}건"    || record_ok "[$ALIAS] OOM 없음"
    [[ "${KPANIC:-0}" -gt 0 ]] && record_fail "[$ALIAS] 커널 패닉: ${KPANIC}건"
    [[ "${IO_ERR:-0}" -gt 0 ]] && record_warn "[$ALIAS] I/O 오류: ${IO_ERR}건"   || record_ok "[$ALIAS] I/O 정상"
    [[ "${RESTARTS:-0}" -gt 1 ]] && record_warn "[$ALIAS] 서비스 재시작: ${RESTARTS}회" \
                                  || print_info  "[$ALIAS] 재시작: ${RESTARTS:-0}회"
  done
  end_sect "system"
fi

# ═════════════════════════════════════════════════════════════════════════════
# B. Nginx — SSH로 로그 수집 후 분석
# ═════════════════════════════════════════════════════════════════════════════
if [[ "$TARGET_ROLE" == "all" || "$TARGET_ROLE" == "nginx" ]]; then
  print_section "B. Nginx — 야간 트래픽 분석 (SSH 로그 수집)"
  begin_sect

  for SERVER in "${NGINX_SERVERS[@]}"; do
    ALIAS=$(get_alias "$SERVER")
    ssh_reachable "$SERVER" || { record_warn "[$ALIAS] SSH 불가"; continue; }

    print_info "[$ALIAS] 액세스 로그 수집 중..."
    NIGHT_ACCESS=$(ssh_extract_log "$SERVER" "/var/log/nginx/access.log" "nginx_access")
    TOTAL=$(echo "$NIGHT_ACCESS" | grep -c . || true)
    C2=$(echo "$NIGHT_ACCESS" | awk '$9~/^2/' | wc -l)
    C4=$(echo "$NIGHT_ACCESS" | awk '$9~/^4/' | wc -l)
    C5=$(echo "$NIGHT_ACCESS" | awk '$9~/^5/' | wc -l)

    print_info "[$ALIAS] 총 요청: ${TOTAL}건  2xx:${C2}  4xx:${C4}  5xx:${C5}"

    if [[ "$TOTAL" -gt 0 ]]; then
      R5=$(awk "BEGIN{printf \"%.1f\", ($C5/$TOTAL)*100}")
      check_threshold "$(printf "%.0f" "$R5")" 2 5 "[$ALIAS] 5xx 에러율" "%"

      print_info "[$ALIAS] 시간대별 요청 분포:"
      echo "$NIGHT_ACCESS" | awk '{match($0,/:([0-9]{2}):[0-9]{2}:[0-9]{2} /,a); if(a[1]) hr[a[1]]++}
        END{for(h in hr) printf "    %s시: %d건\n",h,hr[h]}' | sort

      print_info "[$ALIAS] Top 5 URL:"
      echo "$NIGHT_ACCESS" | awk '{print $7}' | cut -d'?' -f1 | \
        sort | uniq -c | sort -rn | head -5 | awk '{printf "    %5d건  %s\n",$1,$2}'
    else
      print_info "[$ALIAS] 야간 구간 요청 없음"
    fi

    print_info "[$ALIAS] 에러 로그 수집 중..."
    NIGHT_ERR=$(ssh_extract_log "$SERVER" "/var/log/nginx/error.log" "nginx_error")
    CRIT=$(echo "$NIGHT_ERR" | grep -c "\[crit\]\|\[emerg\]" || true)
    ERRC=$(echo "$NIGHT_ERR" | grep -c "\[error\]" || true)
    [[ "${CRIT:-0}" -gt 0 ]] && record_fail "[$ALIAS] crit/emerg: ${CRIT}건" || record_ok "[$ALIAS] crit/emerg 없음"
    [[ "${ERRC:-0}" -gt 5  ]] && record_warn "[$ALIAS] error: ${ERRC}건"      || record_ok "[$ALIAS] error: ${ERRC:-0}건"
  done
  end_sect "nginx"
fi

# ═════════════════════════════════════════════════════════════════════════════
# C. Spring Boot — SSH 로그 + 직접 Actuator
# ═════════════════════════════════════════════════════════════════════════════
if [[ "$TARGET_ROLE" == "all" || "$TARGET_ROLE" == "springboot" ]]; then
  print_section "C. Spring Boot — 야간 앱 분석 (SSH 로그 수집 + Actuator)"
  begin_sect

  for i in "${!SPRING_SERVERS[@]}"; do
    SERVER="${SPRING_SERVERS[$i]}"
    ACTUATOR_BASE="${SPRING_ACTUATOR_URLS[$i]}"   # Nginx 프록시 URL
    ALIAS=$(get_alias "$SERVER")
    APP_NAME="${APP_NAME:-messaging-service}"
    APP_LOG="/var/log/${APP_NAME}/application.log"

    ssh_reachable "$SERVER" || { record_warn "[$ALIAS] SSH 불가"; continue; }

    print_info "[$ALIAS] 앱 로그 수집 중..."
    NIGHT_APP=$(ssh_extract_log "$SERVER" "$APP_LOG" "iso")
    CNT_ERR=$(echo "$NIGHT_APP" | grep -c " ERROR " || true)
    CNT_WRN=$(echo "$NIGHT_APP" | grep -c " WARN "  || true)
    OOM_APP=$(echo "$NIGHT_APP" | grep -c "OutOfMemoryError" || true)
    SOE=$(echo "$NIGHT_APP"     | grep -c "StackOverflowError" || true)
    DB_ERR=$(echo "$NIGHT_APP"  | grep -c "HikariPool\|Connection refused" || true)
    RD_ERR=$(echo "$NIGHT_APP"  | grep -c "RedisConnectionException" || true)

    check_threshold "${CNT_ERR:-0}" 5 50 "[$ALIAS] ERROR 로그" "건"
    [[ "${CNT_WRN:-0}" -gt 100 ]] && record_warn "[$ALIAS] WARN: ${CNT_WRN}건"
    [[ "${OOM_APP:-0}" -gt 0 ]]   && record_fail "[$ALIAS] OOM: ${OOM_APP}건" || record_ok "[$ALIAS] OOM 없음"
    [[ "${SOE:-0}" -gt 0 ]]       && record_warn "[$ALIAS] StackOverflow: ${SOE}건"
    [[ "${DB_ERR:-0}" -gt 0 ]]    && record_warn "[$ALIAS] DB 연결 오류 로그: ${DB_ERR}건"
    [[ "${RD_ERR:-0}" -gt 0 ]]    && record_warn "[$ALIAS] Redis 연결 오류 로그: ${RD_ERR}건"

    if [[ "${CNT_ERR:-0}" -gt 0 ]]; then
      print_info "[$ALIAS] 예외 유형 Top 5:"
      echo "$NIGHT_APP" | grep " ERROR " | grep -oE '[A-Za-z]+Exception|[A-Za-z]+Error' | \
        sort | uniq -c | sort -rn | head -5 | awk '{printf "    %4d건  %s\n",$1,$2}'
      print_info "[$ALIAS] ERROR 시간대 분포:"
      echo "$NIGHT_APP" | grep " ERROR " | \
        awk '{match($0,/([0-9]{4}-[0-9]{2}-[0-9]{2} ([0-9]{2})):/,a); if(a[2]) hr[a[2]]++}
             END{for(h in hr) printf "    %s시: %d건\n",h,hr[h]}' | sort
    fi

    # Actuator 현재 상태 (Nginx 프록시 경유)
    H=$(curl -sk --max-time 5 "${ACTUATOR_BASE}/health" 2>/dev/null || true)
    ST=$(echo "$H" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','N/A'))" 2>/dev/null || echo "N/A")
    [[ "$ST" == "UP" ]] && record_ok "[$ALIAS] Actuator 현재: UP" || record_warn "[$ALIAS] Actuator 현재: ${ST}"
  done
  end_sect "springboot"
fi

# ═════════════════════════════════════════════════════════════════════════════
# D. Redis — 모니터링 서버에서 직접
# ═════════════════════════════════════════════════════════════════════════════
if [[ "$TARGET_ROLE" == "all" || "$TARGET_ROLE" == "redis" ]]; then
  print_section "D. Redis 클러스터 — 야간 분석 (모니터링 서버 직접)"
  begin_sect

  PRIMARY="${REDIS_CLUSTER_NODES[0]}"
  CI=$(redis_cmd "$PRIMARY" CLUSTER INFO)
  if [[ -n "$CI" ]]; then
    CS=$(echo "$CI" | grep "cluster_state:" | cut -d: -f2 | tr -d '\r ')
    SF=$(echo "$CI" | grep "cluster_slots_fail:" | cut -d: -f2 | tr -d '\r ')
    [[ "$CS" == "ok" ]] && record_ok "클러스터 상태: ok" || record_fail "클러스터 상태: $CS"
    [[ "${SF:-0}" -eq 0 ]] && record_ok "FAIL 슬롯 없음" || record_fail "FAIL 슬롯: ${SF}개"
  fi

  NOW_E=$(date +%s)
  for node in "${REDIS_CLUSTER_NODES[@]}"; do
    INFO=$(redis_cmd "$node" INFO all)
    [[ -z "$INFO" ]] && { record_fail "[$node] INFO 실패"; continue; }
    pi() { echo "$INFO" | grep "^$1:" | cut -d: -f2- | tr -d '\r '; }

    ROLE=$(pi role); UM=$(pi used_memory); MM=$(pi maxmemory)
    EV=$(pi evicted_keys); HIT=$(pi keyspace_hits); MISS=$(pi keyspace_misses)
    RSTATUS=$(pi rdb_last_bgsave_status); RLAST=$(pi rdb_last_save_time)
    RJ=$(pi rejected_connections)

    UM_MB=$(awk "BEGIN{printf \"%.1f\", ${UM:-0}/1048576}")
    print_info "[$node] 역할:$ROLE  메모리:${UM_MB}MB"

    if [[ -n "$MM" && "$MM" -gt 0 ]]; then
      MP=$(awk "BEGIN{printf \"%.0f\", (${UM:-0}/$MM)*100}")
      check_threshold "$MP" 75 90 "[$node] 메모리" "%"
    fi

    TH=$(( ${HIT:-0} + ${MISS:-0} ))
    [[ $TH -gt 0 ]] && {
      HR=$(awk "BEGIN{printf \"%.1f\", (${HIT:-0}/$TH)*100}")
      [[ $(printf "%.0f" "$HR") -lt 80 ]] \
        && record_warn "[$node] Hit Rate: ${HR}%" || record_ok "[$node] Hit Rate: ${HR}%"
    }
    [[ "${EV:-0}"  -gt 0 ]] && record_warn "[$node] Evicted: ${EV}개" || record_ok "[$node] Eviction 없음"
    [[ "${RJ:-0}"  -gt 0 ]] && record_warn "[$node] Rejected: ${RJ}건"

    if [[ -n "$RLAST" && "$RLAST" -gt 0 ]]; then
      AGE=$(( NOW_E - RLAST ))
      RDT=$(date -d "@$RLAST" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "epoch:$RLAST")
      [[ "$RSTATUS" == "ok" && $AGE -le 3600 ]] \
        && record_ok "[$node] RDB 백업 ($RDT)" || record_warn "[$node] RDB 오래됨 ($RDT, ${AGE}초 전)"
    fi

    [[ "$ROLE" == "slave" ]] && {
      LS=$(pi master_link_status)
      [[ "$LS" == "up" ]] && record_ok "[$node] 복제: up" || record_fail "[$node] 복제: $LS"
    }
  done

  # 큐 적체
  print_info "── 메시지 큐 현황 ──"
  for node in "${REDIS_CLUSTER_NODES[@]}"; do
    for key in "${QUEUE_KEYS[@]-queue:messages queue:notifications queue:events}"; do
      KT=$(redis_cmd "$node" TYPE "$key")
      case "$KT" in
        list)   LEN=$(redis_cmd "$node" LLEN "$key")
                check_threshold "${LEN:-0}" 10000 50000 "[$node] $key" "건" ;;
        stream) LEN=$(redis_cmd "$node" XLEN "$key")
                check_threshold "${LEN:-0}" 10000 50000 "[$node] $key (Stream)" "건" ;;
        none)   print_info "  [$node] $key: 없음" ;;
      esac
    done
  done
  end_sect "redis"
fi

# ═════════════════════════════════════════════════════════════════════════════
# E. MySQL — 모니터링 서버에서 직접 + SSH 슬로우 로그
# ═════════════════════════════════════════════════════════════════════════════
if [[ "$TARGET_ROLE" == "all" || "$TARGET_ROLE" == "mysql" ]]; then
  print_section "E. MySQL — 야간 복제 및 슬로우 쿼리 분석"
  begin_sect

  # 별칭 → 터널 로컬 호스트/포트 매핑 (inventory.sh 기준)
  declare -A MYSQL_HOST_MAP=(["mysql-primary"]="$MYSQL_PRIMARY_HOST" ["mysql-replica"]="$MYSQL_REPLICA_HOST")
  declare -A MYSQL_PORT_MAP=(["mysql-primary"]="$MYSQL_PRIMARY_PORT" ["mysql-replica"]="$MYSQL_REPLICA_PORT")

  for SERVER in "${MYSQL_SERVERS[@]}"; do
    ALIAS=$(get_alias "$SERVER")
    DB_HOST="${MYSQL_HOST_MAP[$ALIAS]}"
    DB_PORT="${MYSQL_PORT_MAP[$ALIAS]}"

    print_info "[$ALIAS] 터널 접속: ${DB_HOST}:${DB_PORT}"

    [[ "$(mysql_exec "$DB_HOST" "$DB_PORT" "SELECT 1;" 2>/dev/null)" != "1" ]] && {
      record_warn "[$ALIAS] DB 접속 불가 (터널 포트: ${DB_PORT})"; continue; }

    RO=$(mysql_exec "$DB_HOST" "$DB_PORT" "SELECT @@read_only;")
    ROLE=$( [[ "$RO" == "0" ]] && echo "PRIMARY" || echo "REPLICA" )
    print_info "[$ALIAS] 역할: $ROLE"

    if [[ "$ROLE" == "REPLICA" ]]; then
      RS=$(mysql_exec "$DB_HOST" "$DB_PORT" "SHOW REPLICA STATUS\G" 2>/dev/null)
      [[ -z "$RS" ]] && RS=$(mysql_exec "$DB_HOST" "$DB_PORT" "SHOW SLAVE STATUS\G" 2>/dev/null)
      if [[ -n "$RS" ]]; then
        gr() { echo "$RS" | grep -E "^\s*$1:" | awk -F': ' '{print $2}' | tr -d ' '; }
        IO=$(gr "Slave_IO_Running\|Replica_IO_Running")
        SQL=$(gr "Slave_SQL_Running\|Replica_SQL_Running")
        LAG=$(gr "Seconds_Behind_Master\|Seconds_Behind_Source")
        IE=$(gr "Last_IO_Error"); SE=$(gr "Last_SQL_Error")
        [[ "$IO"  == "Yes" ]] && record_ok "[$ALIAS] IO Thread: Yes"  || record_fail "[$ALIAS] IO Thread: ${IO:-N/A}"
        [[ "$SQL" == "Yes" ]] && record_ok "[$ALIAS] SQL Thread: Yes" || record_fail "[$ALIAS] SQL Thread: ${SQL:-N/A}"
        [[ "$LAG" == "NULL" || -z "$LAG" ]] \
          && record_warn "[$ALIAS] 복제 지연 측정 불가" \
          || check_threshold "$LAG" 30 120 "[$ALIAS] 복제 지연" "초"
        [[ -n "$IE" ]] && record_fail "[$ALIAS] IO 오류: $IE"
        [[ -n "$SE" ]] && record_fail "[$ALIAS] SQL 오류: $SE"
      fi
    fi

    # InnoDB
    DL=$(mysql_exec "$DB_HOST" "$DB_PORT" "SHOW GLOBAL STATUS LIKE 'Innodb_deadlocks';" | awk '{print $2}')
    BR=$(mysql_exec "$DB_HOST" "$DB_PORT" "SHOW STATUS LIKE 'Innodb_buffer_pool_reads';"         | awk '{print $2}')
    BQ=$(mysql_exec "$DB_HOST" "$DB_PORT" "SHOW STATUS LIKE 'Innodb_buffer_pool_read_requests';" | awk '{print $2}')
    [[ "${DL:-0}" -gt 0 ]] && record_fail "[$ALIAS] 데드락: ${DL}건" || record_ok "[$ALIAS] 데드락 없음"
    if [[ -n "$BQ" && "$BQ" -gt 0 ]]; then
      HT=$(awk "BEGIN{printf \"%.1f\", (1-(${BR:-0}/$BQ))*100}")
      [[ $(printf "%.0f" "$HT") -lt 90 ]] \
        && record_warn "[$ALIAS] Buffer Pool Hit: ${HT}%" || record_ok "[$ALIAS] Buffer Pool Hit: ${HT}%"
    fi

    # 슬로우 쿼리 로그 SSH 수집
    SLF=$(mysql_exec "$DB_HOST" "$DB_PORT" "SELECT @@slow_query_log_file;" 2>/dev/null | head -1 | tr -d ' \n')
    SLO=$(mysql_exec "$DB_HOST" "$DB_PORT" "SELECT @@slow_query_log;")
    if [[ "$SLO" == "1" && -n "$SLF" ]]; then
      print_info "[$ALIAS] 슬로우 쿼리 로그 SSH 수집 중..."
      NIGHT_SL=$(ssh_extract_log "$SERVER" "$SLF" "iso")
      SC=$(echo "$NIGHT_SL" | grep -c "^# Query_time" || true)
      check_threshold "${SC:-0}" 50 200 "[$ALIAS] 야간 슬로우 쿼리" "건"
      if [[ "${SC:-0}" -gt 0 ]]; then
        print_info "[$ALIAS] Top 5 슬로우 쿼리 패턴:"
        echo "$NIGHT_SL" | grep -A1 "^# Query_time" | grep -E "^(SELECT|INSERT|UPDATE|DELETE)" | \
          sed 's/[0-9]\{8,\}/N/g' | sort | uniq -c | sort -rn | head -5 | \
          awk '{printf "    %4d건  %s\n",$1,substr($0,index($0,$2))}'
      fi
    fi

    # Performance Schema
    PT=$(mysql_exec "$DB_HOST" "$DB_PORT" "
      SELECT ROUND(avg_timer_wait/1e9,2), exec_count, SUBSTR(REPLACE(digest_text,'\n',' '),1,70)
      FROM performance_schema.events_statements_summary_by_digest
      ORDER BY avg_timer_wait DESC LIMIT 5;" 2>/dev/null)
    if [[ -n "$PT" ]]; then
      print_info "[$ALIAS] Performance Schema TOP 5:"
      echo "$PT" | awk '{printf "    avg:%6sms  cnt:%5s  %s\n",$1,$2,$3}'
    fi
  done
  end_sect "mysql"
fi

# ═════════════════════════════════════════════════════════════════════════════
# F. 인프라 스냅샷 (모니터링 서버 시각 기준)
# ═════════════════════════════════════════════════════════════════════════════
print_section "F. 인프라 스냅샷 ($(date '+%H:%M:%S') 기준)"
print_info "전체 서버 SSH 접속 가능 여부:"
for SERVER in "${ALL_SERVERS[@]}"; do
  ALIAS=$(get_alias "$SERVER"); HOST=$(get_host "$SERVER")
  ssh_reachable "$SERVER" && record_ok "[$ALIAS] SSH 접속 가능" || record_warn "[$ALIAS] SSH 접속 불가"
done
print_info "Exporter 응답 확인 (19100 프록시 경유):"
for entry in "${NODE_EXPORTER_URLS[@]}"; do
  alias="${entry%%:*}"; url="${entry#*:}"
  check_http "${url}/metrics" "[${alias}] Node Exporter" 200
done
for entry in "${REDIS_EXPORTER_URLS[@]}"; do
  alias="${entry%%:*}"; url="${entry#*:}"
  check_http "${url}/metrics" "[${alias}] Redis Exporter" 200
done
if [[ ${#MYSQLD_EXPORTER_URLS[@]} -gt 0 ]]; then
  for entry in "${MYSQLD_EXPORTER_URLS[@]}"; do
    alias="${entry%%:*}"; url="${entry#*:}"
    check_http "${url}/metrics" "[${alias}] mysqld_exporter" 200
  done
else
  print_info "mysqld_exporter: monitoring.conf 에 경로 미설정 (점검 건너뜀)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 최종 요약 대시보드
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${BLUE}"
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║                        야간 통합 점검 요약                           ║"
echo "╠═══════════════════════════╦════════════╦════════════╦════════════════╣"
echo "║  섹션                     ║  OK        ║  WARN      ║  FAIL          ║"
echo "╠═══════════════════════════╬════════════╬════════════╬════════════════╣"
declare -A LMAP=([system]="A. 시스템/커널" [nginx]="B. Nginx" [springboot]="C. Spring Boot" [redis]="D. Redis" [mysql]="E. MySQL")
for k in system nginx springboot redis mysql; do
  [[ -z "${SECT_OK[$k]+x}" ]] && continue
  printf "║  %-25s║  %-10s║  %-10s║  %-14s║\n" "${LMAP[$k]}" "${SECT_OK[$k]}" "${SECT_WARN[$k]}" "${SECT_FAIL[$k]}"
done
echo "╠═══════════════════════════╬════════════╬════════════╬════════════════╣"
printf "║  %-25s║  %-10s║  %-10s║  %-14s║\n" "합계" "$RESULT_OK" "$RESULT_WARN" "$RESULT_FAIL"
echo "╚═══════════════════════════╩════════════╩════════════╩════════════════╝"
echo -e "${NC}"

[[ $RESULT_FAIL -gt 0 ]] && echo -e "  ${RED}${BOLD}▶ 최종 상태: 장애 발생 — 즉시 확인 필요${NC}"
[[ $RESULT_FAIL -eq 0 && $RESULT_WARN -gt 0 ]] && echo -e "  ${YELLOW}${BOLD}▶ 최종 상태: 경고 — 금일 모니터링 강화 권장${NC}"
[[ $RESULT_FAIL -eq 0 && $RESULT_WARN -eq 0 ]] && echo -e "  ${GREEN}${BOLD}▶ 최종 상태: 정상 — 야간 이상 없음${NC}"

echo ""
echo -e "  ${BOLD}리포트: ${REPORT_FILE}${NC}"
ln -sf "$REPORT_FILE" "$LATEST_LINK" 2>/dev/null || true
echo -e "  ${BOLD}최신본: ${LATEST_LINK}${NC}"
echo ""
