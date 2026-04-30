#!/bin/bash
# =============================================================================
# remote-agent/local_check.sh
# 각 대상 서버에 배포되는 로컬 전용 점검 에이전트
#
# 목적: 모니터링 서버에서 네트워크로 수집 불가능한 로컬 정보만 담당
#       - 프로세스 상태 (/proc)
#       - 파일 디스크립터
#       - 로컬 로그 파일 (최근 N줄 요약)
#       - systemd 서비스 상태
#       - 커널 이벤트 (journalctl)
#       - 디스크 / CPU / 메모리
#
# 출력: JSON 형식 → 모니터링 서버에서 파싱
#
# 사용법:
#   bash local_check.sh --role nginx
#   bash local_check.sh --role springboot
#   bash local_check.sh --role redis
#   bash local_check.sh --role mysql
#   bash local_check.sh --role all
#   bash local_check.sh --role springboot --log-lines 500
# =============================================================================

ROLE="all"
LOG_LINES=200   # 로그 분석 줄 수

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)      ROLE="$2";      shift 2 ;;
    --log-lines) LOG_LINES="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ── JSON 출력 헬퍼 ────────────────────────────────────────────────────────
# JSON을 직접 조립 (jq 의존 없이)
OUT="{}"

jset() {
  # jset key value [type]
  # type: string(기본) | number | bool | raw
  local key="$1" val="$2" type="${3:-string}"
  if [[ "$type" == "number" || "$type" == "bool" ]]; then
    OUT=$(echo "$OUT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
d['$key']=$val
print(json.dumps(d))
" 2>/dev/null || echo "$OUT")
  else
    local escaped
    escaped=$(echo "$val" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/g' | tr -d '\n' | sed 's/\\n$//')
    OUT=$(echo "$OUT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
d['$key']='${escaped}'
print(json.dumps(d))
" 2>/dev/null || echo "$OUT")
  fi
}

# ── 공통: 시스템 리소스 ──────────────────────────────────────────────────
collect_system() {
  # CPU loadavg
  local load1 load5 load15 cores
  read -r load1 load5 load15 _ < /proc/loadavg
  cores=$(nproc 2>/dev/null || echo 1)
  local cpu_pct
  cpu_pct=$(awk "BEGIN{printf \"%.1f\", ($load1/$cores)*100}")

  # 메모리
  local mem_total mem_used mem_avail mem_pct
  read -r mem_total mem_used mem_avail <<< \
    "$(free -m 2>/dev/null | awk 'NR==2{print $2,$3,$7}')"
  mem_pct=$(awk "BEGIN{printf \"%.1f\", (${mem_used:-0}/${mem_total:-1})*100}")

  # 디스크
  local disk_root
  disk_root=$(df / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')

  # 업타임
  local uptime_sec
  uptime_sec=$(awk '{printf "%.0f", $1}' /proc/uptime)

  # 커널 이벤트 (최근 60분)
  local kernel_errors
  kernel_errors=$(journalctl -k --since "-60min" -p err..emerg --no-pager 2>/dev/null \
    | grep -c . 2>/dev/null || true)
  kernel_errors=${kernel_errors:-0}

  # OOM (최근 60분)
  local oom_count
  oom_count=$(journalctl -k --since "-60min" --no-pager 2>/dev/null \
    | grep -c "Out of memory\|oom_kill_process" 2>/dev/null || true)
  oom_count=${oom_count:-0}

  OUT=$(python3 -c "
import json
d=$OUT if '$OUT' != '{}' else {}
try:
    d.update({
      'system': {
        'cpu_load1': '$load1',
        'cpu_load5': '$load5',
        'cpu_pct': $cpu_pct,
        'cpu_cores': $cores,
        'mem_total_mb': ${mem_total:-0},
        'mem_used_mb': ${mem_used:-0},
        'mem_pct': $mem_pct,
        'disk_root_pct': ${disk_root:-0},
        'uptime_sec': $uptime_sec,
        'kernel_errors_60m': ${kernel_errors:-0},
        'oom_60m': ${oom_count:-0}
      }
    })
    print(json.dumps(d))
except Exception as e:
    print('{}')
" 2>/dev/null || echo "{}")
}

# ── Nginx 로컬 점검 ───────────────────────────────────────────────────────
collect_nginx() {
  local nginx_master_pid nginx_worker_count
  nginx_master_pid=$(pgrep -f "nginx: master" 2>/dev/null | head -1)
  nginx_worker_count=$(pgrep -c -f "nginx: worker" 2>/dev/null || echo 0)

  local nginx_conf_ok nginx_conf_msg
  nginx_conf_msg=$(nginx -t 2>&1) && nginx_conf_ok="true" || nginx_conf_ok="false"
  CONF_MSG=$(echo "$nginx_conf_msg" | head -3 | tr '\n' ' ' | sed "s/'/\"/g")  # ← 추가

  # 에러 로그 최근 5분
  local error_log="/var/log/nginx/error.log"
  local error_5m=0 error_patterns=""
  if [[ -f "$error_log" ]]; then
    local five_ago
    five_ago=$(date -d '5 minutes ago' '+%Y/%m/%d %H:%M' 2>/dev/null || date -v-5M '+%Y/%m/%d %H:%M')
    error_5m=$(awk -v d="$five_ago" \
      'substr($0,1,16) >= d && /\[error\]|\[crit\]|\[emerg\]/{c++} END{print c+0}' \
      "$error_log" 2>/dev/null || echo 0)
    error_patterns=$(grep -E '\[error\]|\[crit\]|\[emerg\]' "$error_log" 2>/dev/null \
      | tail -200 | awk '{$1=$2=$3=""; print $0}' | sort | uniq -c | sort -rn | head -3 \
      | sed 's/"/\\"/g' | tr '\n' '|' | sed 's/|$//')
  fi

  local disk_log
  disk_log=$(df /var/log/nginx 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}' || echo 0)
  OUT=$(CONF_MSG="$CONF_MSG" \
        ERROR_PATTERNS="$error_patterns" \
        OUT_JSON="$OUT" \
        MASTER_PID="${nginx_master_pid:-}" \
        WORKER_COUNT="${nginx_worker_count}" \
        CONF_OK="${nginx_conf_ok}" \
        ERROR_5M="${error_5m}" \
        DISK_LOG="${disk_log}" \
        python3 -c "
import json, os
d = json.loads(os.environ.get('OUT_JSON', '{}'))
try:
    d['nginx'] = {
      'master_pid': os.environ.get('MASTER_PID',''),
      'worker_count': int(os.environ.get('WORKER_COUNT', 0)),
      'conf_ok': os.environ.get('CONF_OK','false') == 'true',
      'conf_msg': os.environ.get('CONF_MSG',''),
      'error_log_5m': int(os.environ.get('ERROR_5M', 0)),
      'error_patterns': os.environ.get('ERROR_PATTERNS',''),
      'disk_log_pct': int(os.environ.get('DISK_LOG', 0))
    }
    print(json.dumps(d))
except Exception as e:
    import sys
    print(e, file=sys.stderr)
    print(json.dumps(d))
" 2>&1)

# ── Spring Boot 로컬 점검 ────────────────────────────────────────────────
collect_springboot() {
  # 1. 프로세스는 두 서버 공통인 jar 파일명으로 찾기
  local proc_pattern="messaging/engine.jar"
  # 2. 로그는 각 서버의 이름에 맞게 자동 설정
  local svr_name=$(hostname -s)
  local app_log="/var/log/app/${svr_name}.log"
  # 3. PID 추출
  app_pid=$(pgrep -f "$proc_pattern" 2>/dev/null | head -1)

  if [[ -n "$app_pid" ]]; then
    local uptime_sec
    uptime_sec=$(ps -o etimes= -p "$app_pid" 2>/dev/null | tr -d ' ')
    app_uptime_min=$(( ${uptime_sec:-0} / 60 ))
    rss_mb=$(awk '/VmRSS/{printf "%.0f", $2/1024}' /proc/$app_pid/status 2>/dev/null || echo 0)
    fd_count=$(ls /proc/$app_pid/fd 2>/dev/null | wc -l)
    fd_limit=$(awk '/open files/{print $4; exit}' /proc/$app_pid/limits 2>/dev/null || echo 0)
    if [[ "${fd_limit:-0}" -gt 0 ]]; then
      fd_pct=$(awk "BEGIN{printf \"%.0f\", ($fd_count/$fd_limit)*100}")
    else
      fd_pct=0
    fi
  else
    app_uptime_min=0; rss_mb=0; fd_count=0; fd_limit=0; fd_pct=0
  fi

  # 로그 분석 (최근 LOG_LINES 줄)
  local error_5m=0 warn_5m=0 oom_total=0 soe_total=0 error_types=""
  if [[ -f "$app_log" ]]; then
    local since
    since=$(date -d '5 minutes ago' '+%Y-%m-%d %H:%M' 2>/dev/null || date -v-5M '+%Y-%m-%d %H:%M')
    local recent_log
    recent_log=$(tail -"$LOG_LINES" "$app_log" 2>/dev/null)
    error_5m=$(echo "$recent_log" | awk -v d="$since" '$0>=d && / ERROR /' | wc -l)
    warn_5m=$(echo  "$recent_log" | awk -v d="$since" '$0>=d && / WARN /'  | wc -l)
    oom_total=$(grep -c "OutOfMemoryError"   "$app_log" 2>/dev/null || echo 0)
    soe_total=$(grep -c "StackOverflowError" "$app_log" 2>/dev/null || echo 0)
    error_types=$(echo "$recent_log" | grep ' ERROR ' \
      | grep -oE '[A-Za-z]+Exception|[A-Za-z]+Error' \
      | sort | uniq -c | sort -rn | head -5 \
      | awk '{printf "%s:%s|", $2, $1}' | sed 's/|$//')
  fi

  # Full GC (GC 로그)
  local full_gc=0
  [[ -f "$gc_log" ]] && full_gc=$(grep -c "Full GC\|Pause Full" "$gc_log" 2>/dev/null || echo 0)

  # 디스크 (앱 로그 디렉토리)
  local disk_applog
  disk_applog=$(df "$(dirname "$app_log")" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}' || echo 0)

  OUT=$(python3 -c "
import json
d=json.loads('$OUT') if '$OUT' != '{}' else {}
try:
    d['springboot'] = {
      'pid': '${app_pid:-}',
      'uptime_min': ${app_uptime_min},
      'rss_mb': ${rss_mb},
      'fd_count': ${fd_count},
      'fd_limit': ${fd_limit},
      'fd_pct': ${fd_pct},
      'error_5m': ${error_5m},
      'warn_5m': ${warn_5m},
      'oom_total': ${oom_total},
      'soe_total': ${soe_total},
      'error_types': '${error_types}',
      'full_gc': ${full_gc},
      'disk_applog_pct': ${disk_applog}
    }
    print(json.dumps(d))
except:
    print(json.dumps(d))
" 2>/dev/null || echo "$OUT")
}

# ── Redis 로컬 점검 ───────────────────────────────────────────────────────
collect_redis() {
  local redis_pid redis_conf_file
  redis_pid=$(pgrep -x redis-server 2>/dev/null | head -1)

  # systemd 상태
  local svc_status
  svc_status=$(systemctl is-active redis 2>/dev/null \
            || systemctl is-active redis-server 2>/dev/null \
            || echo "unknown")

  # 데이터 디렉토리 디스크
  local redis_datadir disk_data
  redis_datadir=$(redis-cli CONFIG GET dir 2>/dev/null | tail -1 || echo "/var/lib/redis")
  disk_data=$(df "${redis_datadir:-/var/lib/redis}" 2>/dev/null \
    | awk 'NR==2{gsub(/%/,"",$5); print $5}' || echo 0)

  # 커널: 투명 거대 페이지(THP) 경고
  local thp_status
  thp_status=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null \
    | grep -o '\[.*\]' | tr -d '[]')

  OUT=$(python3 -c "
import json
d=json.loads('$OUT') if '$OUT' != '{}' else {}
try:
    d['redis_local'] = {
      'pid': '${redis_pid:-}',
      'svc_status': '${svc_status}',
      'disk_data_pct': ${disk_data},
      'thp_status': '${thp_status:-unknown}'
    }
    print(json.dumps(d))
except:
    print(json.dumps(d))
" 2>/dev/null || echo "$OUT")
}

# ── MySQL 로컬 점검 ───────────────────────────────────────────────────────
collect_mysql() {
  local mysql_pid svc_status
  mysql_pid=$(pgrep -x mysqld 2>/dev/null | head -1)
  svc_status=$(systemctl is-active mysql 2>/dev/null \
            || systemctl is-active mysqld 2>/dev/null \
            || echo "unknown")

  # 슬로우 쿼리 로그 파일 크기 및 최근 건수
  # (접속이 필요한 쿼리는 모니터링 서버에서 직접 수행)
  local slow_log_file slow_log_size_mb=0
  slow_log_file=$(mysql -e "SELECT @@slow_query_log_file;" -sN 2>/dev/null | head -1)
  if [[ -f "${slow_log_file:-}" ]]; then
    slow_log_size_mb=$(du -m "$slow_log_file" 2>/dev/null | awk '{print $1}')
  fi

  # 데이터 디렉토리 디스크
  local datadir disk_data
  datadir=$(mysql -e "SELECT @@datadir;" -sN 2>/dev/null | head -1 || echo "/var/lib/mysql")
  disk_data=$(df "${datadir:-/var/lib/mysql}" 2>/dev/null \
    | awk 'NR==2{gsub(/%/,"",$5); print $5}' || echo 0)

  # Binlog 디스크 사용량
  local binlog_total_mb=0
  if [[ -n "$datadir" ]]; then
    binlog_total_mb=$(du -sm "${datadir}"mysql-bin.* 2>/dev/null | \
      awk '{s+=$1} END{print s+0}')
  fi

  OUT=$(python3 -c "
import json
d=json.loads('$OUT') if '$OUT' != '{}' else {}
try:
    d['mysql_local'] = {
      'pid': '${mysql_pid:-}',
      'svc_status': '${svc_status}',
      'disk_data_pct': ${disk_data},
      'slow_log_file': '${slow_log_file:-}',
      'slow_log_size_mb': ${slow_log_size_mb:-0},
      'binlog_total_mb': ${binlog_total_mb:-0}
    }
    print(json.dumps(d))
except:
    print(json.dumps(d))
" 2>/dev/null || echo "$OUT")
}

# ── 실행 ─────────────────────────────────────────────────────────────────
collect_system

case "$ROLE" in
  nginx)       collect_nginx ;;
  springboot)  collect_springboot ;;
  redis)       collect_redis ;;
  mysql)       collect_mysql ;;
  all)
    collect_nginx
    collect_springboot
    collect_redis
    collect_mysql
    ;;
esac

# JSON 최종 출력 (모니터링 서버에서 파싱)
echo "$OUT"
