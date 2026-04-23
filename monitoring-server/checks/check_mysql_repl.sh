#!/bin/bash
# =============================================================================
# monitoring-server/checks/check_mysql_repl.sh  v4
#
# 변경 내용:
#   - MySQL 직접 접근(192.168.10.40:3306) → SSH 터널(127.0.0.1:13306/13307) 경유
#   - mysql_exec 함수가 MYSQL_PRIMARY_PORT / MYSQL_REPLICA_PORT 사용
#   - 터널 생존 여부 점검 시작 시 확인
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/utils.sh"
source "$SCRIPT_DIR/../common/inventory.sh"

# ── Exporter 상태 확인 헬퍼 (19100 프록시 경유) ──────────────────────────────
check_node_exporter() {
  local alias="$1"
  local url=""
  for entry in "${NODE_EXPORTER_URLS[@]}"; do
    if [[ "${entry%%:*}" == "$alias" ]]; then
      url="${entry#*:}"; break
    fi
  done
  if [[ -z "$url" ]]; then
    print_info "[$alias] Node Exporter URL 미설정 (servers.conf 확인)"
    return
  fi
  check_http "$url/metrics" "[$alias] Node Exporter" 200
}

check_redis_exporter() {
  local alias="$1"
  local url=""
  for entry in "${REDIS_EXPORTER_URLS[@]}"; do
    if [[ "${entry%%:*}" == "$alias" ]]; then
      url="${entry#*:}"; break
    fi
  done
  if [[ -z "$url" ]]; then
    print_info "[$alias] Redis Exporter URL 미설정 (servers.conf 확인)"
    return
  fi
  check_http "$url/metrics" "[$alias] Redis Exporter" 200
}

check_mysqld_exporter() {
  local alias="$1"
  local url=""
  for entry in "${MYSQLD_EXPORTER_URLS[@]}"; do
    if [[ "${entry%%:*}" == "$alias" ]]; then
      url="${entry#*:}"; break
    fi
  done
  if [[ -z "$url" ]]; then
    print_info "[$alias] mysqld_exporter URL 미설정 (monitoring.conf 에 경로 추가 필요)"
    return
  fi
  check_http "$url/metrics" "[$alias] mysqld_exporter" 200
}

REPL_LAG_WARN=$MYSQL_REPL_LAG_WARN;     REPL_LAG_FAIL=$MYSQL_REPL_LAG_FAIL
CONN_WARN=$MYSQL_CONN_WARN;       CONN_FAIL=$MYSQL_CONN_FAIL
THREAD_WARN=$MYSQL_THREAD_WARN;    THREAD_FAIL=$MYSQL_THREAD_FAIL
SLOW_QUERY_WARN=$MYSQL_SLOW_QUERY_WARN
DEAD_LOCK_WARN=$MYSQL_DEADLOCK_WARN
BUF_HIT_WARN=$MYSQL_BUF_HIT_WARN;    BUF_HIT_FAIL=$MYSQL_BUF_HIT_FAIL
DISK_WARN=$SYS_DISK_WARN;          DISK_FAIL=$SYS_DISK_FAIL

init_log "mysql_repl_check"
print_header "MySQL 복제 점검 (SSH 터널 경유) | $DATE_LABEL"

# mysql_exec: 호스트와 포트를 받아 쿼리 실행
mysql_exec() {
  local host="$1" port="$2" query="$3"
  if [[ -f "$MYSQL_CNF" ]]; then
    mysql --defaults-file="$MYSQL_CNF" -h "$host" -P "$port" \
      --connect-timeout=5 -sNe "$query" 2>/dev/null || true
  elif [[ -n "$MYSQL_PASS" ]]; then
    mysql -u "$MYSQL_USER" -p"$MYSQL_PASS" -h "$host" -P "$port" \
      --connect-timeout=5 -sNe "$query" 2>/dev/null || true
  else
    mysql -u "$MYSQL_USER" -h "$host" -P "$port" \
      --connect-timeout=5 -sNe "$query" 2>/dev/null || true
  fi
}

get_replica_status() {
  local host="$1" port="$2"
  local r
  r=$(mysql_exec "$host" "$port" "SHOW REPLICA STATUS\G" 2>/dev/null)
  [[ -z "$r" ]] && r=$(mysql_exec "$host" "$port" "SHOW SLAVE STATUS\G" 2>/dev/null)
  echo "$r"
}

# 서버 별칭 → 터널 로컬 포트 매핑
declare -A DB_HOST_MAP=(["mysql-primary"]="$MYSQL_PRIMARY_HOST" ["mysql-replica"]="$MYSQL_REPLICA_HOST")
declare -A DB_PORT_MAP=(["mysql-primary"]="$MYSQL_PRIMARY_PORT" ["mysql-replica"]="$MYSQL_REPLICA_PORT")

# ── 터널 상태 사전 확인 ──────────────────────────────────────────────────
print_section "0. SSH 터널 상태 확인"
for entry in "${MYSQL_TUNNEL_MAP[@]}"; do
  IFS=':' read -r _ _ alias _ local_port <<< "$entry"
  if check_tunnel_alive "$local_port" "mysql[$alias]"; then
    record_ok "터널 mysql[$alias] → 127.0.0.1:${local_port} 응답"
  else
    record_fail "터널 mysql[$alias] → 127.0.0.1:${local_port} 응답 없음"
  fi
done

for SERVER in "${MYSQL_SERVERS[@]}"; do
  ALIAS=$(get_alias "$SERVER")
  SSH_HOST=$(get_host "$SERVER")
  DB_HOST="${DB_HOST_MAP[$ALIAS]}"
  DB_PORT="${DB_PORT_MAP[$ALIAS]}"

  print_section "[ $ALIAS — 터널: ${DB_HOST}:${DB_PORT} ]"

  # ── ① DB 쿼리 (터널 경유) ─────────────────────────────────────────────
  print_section "  1. DB 접속 및 기본 현황"
  check_port "$DB_HOST" "$DB_PORT" "[$ALIAS] MySQL 터널(${DB_PORT})"

  DB_OK=false
  if [[ "$(mysql_exec "$DB_HOST" "$DB_PORT" "SELECT 1;")" == "1" ]]; then
    record_ok "[$ALIAS] DB 접속 정상"
    DB_OK=true
  else
    record_fail "[$ALIAS] DB 접속 실패 (터널 포트: ${DB_PORT})"
  fi

  VER=$(mysql_exec "$DB_HOST" "$DB_PORT" "SELECT VERSION();" 2>/dev/null)
  [[ -n "$VER" ]] && print_info "[$ALIAS] MySQL $VER"

  if $DB_OK; then
    MAX_C=$(mysql_exec "$DB_HOST" "$DB_PORT" "SELECT @@max_connections;")
    CUR_C=$(mysql_exec "$DB_HOST" "$DB_PORT" "SHOW STATUS LIKE 'Threads_connected';"  | awk '{print $2}')
    THR_R=$(mysql_exec "$DB_HOST" "$DB_PORT" "SHOW STATUS LIKE 'Threads_running';"    | awk '{print $2}')
    MAX_U=$(mysql_exec "$DB_HOST" "$DB_PORT" "SHOW STATUS LIKE 'Max_used_connections';" | awk '{print $2}')
    AB_C=$(mysql_exec  "$DB_HOST" "$DB_PORT" "SHOW STATUS LIKE 'Aborted_connects';"   | awk '{print $2}')
    AB_CL=$(mysql_exec "$DB_HOST" "$DB_PORT" "SHOW STATUS LIKE 'Aborted_clients';"    | awk '{print $2}')

    if [[ -n "$MAX_C" && -n "$CUR_C" && "$MAX_C" -gt 0 ]]; then
      check_threshold "$(awk "BEGIN{printf \"%.0f\", ($CUR_C/$MAX_C)*100}")" \
        "$CONN_WARN" "$CONN_FAIL" "[$ALIAS] 연결 (${CUR_C}/${MAX_C})" "%"
    fi
    check_threshold "${THR_R:-0}" "$THREAD_WARN" "$THREAD_FAIL" "[$ALIAS] Threads_running" "개"
    print_info "[$ALIAS] 최대 연결 기록: ${MAX_U}개"
    [[ "${AB_C:-0}"  -gt 10 ]] && record_warn "[$ALIAS] Aborted_connects: ${AB_C}건"
    [[ "${AB_CL:-0}" -gt 10 ]] && record_warn "[$ALIAS] Aborted_clients: ${AB_CL}건"

    LONG_Q=$(mysql_exec "$DB_HOST" "$DB_PORT" "
      SELECT COUNT(*) FROM information_schema.processlist
      WHERE COMMAND != 'Sleep' AND TIME > 10;")
    if [[ "${LONG_Q:-0}" -gt 0 ]]; then
      record_warn "[$ALIAS] 장기 실행 쿼리: ${LONG_Q}건 (10초+)"
      mysql_exec "$DB_HOST" "$DB_PORT" "
        SELECT ID,USER,HOST,TIME,LEFT(INFO,60)
        FROM information_schema.processlist
        WHERE COMMAND != 'Sleep' AND TIME > 10
        ORDER BY TIME DESC LIMIT 3;" 2>/dev/null | \
        while IFS=$'\t' read -r id usr hst tm info; do
          print_info "  ID:$id  USER:$usr  TIME:${tm}s  SQL:$info"
        done
    else
      record_ok "[$ALIAS] 장기 실행 쿼리 없음"
    fi

    # 복제 상태
    print_section "  2. 복제 상태"
    RO=$(mysql_exec "$DB_HOST" "$DB_PORT" "SELECT @@read_only;")
    ROLE=$( [[ "$RO" == "0" ]] && echo "PRIMARY" || echo "REPLICA" )
    print_info "[$ALIAS] 역할: $ROLE"

    if [[ "$ROLE" == "REPLICA" ]]; then
      RS=$(get_replica_status "$DB_HOST" "$DB_PORT")
      if [[ -z "$RS" ]]; then
        record_warn "[$ALIAS] 복제 상태 조회 실패"
      else
        gr() { echo "$RS" | grep -E "^\s*$1:" | awk -F': ' '{print $2}' | tr -d ' '; }
        IO=$(gr "Slave_IO_Running\|Replica_IO_Running")
        SQL=$(gr "Slave_SQL_Running\|Replica_SQL_Running")
        LAG=$(gr "Seconds_Behind_Master\|Seconds_Behind_Source")
        IE=$(gr "Last_IO_Error"); SE=$(gr "Last_SQL_Error")
        EXEC_G=$(gr "Executed_Gtid_Set"); RETR_G=$(gr "Retrieved_Gtid_Set")

        [[ "$IO"  == "Yes" ]] && record_ok "[$ALIAS] IO Thread"   || record_fail "[$ALIAS] IO Thread: ${IO:-N/A}"
        [[ "$SQL" == "Yes" ]] && record_ok "[$ALIAS] SQL Thread"  || record_fail "[$ALIAS] SQL Thread: ${SQL:-N/A}"
        [[ "$LAG" == "NULL" || -z "$LAG" ]] \
          && record_warn "[$ALIAS] 복제 지연 측정 불가" \
          || check_threshold "$LAG" "$REPL_LAG_WARN" "$REPL_LAG_FAIL" "[$ALIAS] 복제 지연" "초"
        [[ -n "$IE" ]] && record_fail "[$ALIAS] IO 오류: $IE"
        [[ -n "$SE" ]] && record_fail "[$ALIAS] SQL 오류: $SE"
        [[ -n "$EXEC_G" && -n "$RETR_G" && "$EXEC_G" != "$RETR_G" ]] \
          && record_warn "[$ALIAS] GTID 불일치"
      fi
    else
      record_ok "[$ALIAS] PRIMARY (read_only=OFF)"
      BL=$(mysql_exec "$DB_HOST" "$DB_PORT" "SELECT @@log_bin;")
      [[ "$BL" == "1" ]] && record_ok "[$ALIAS] Binary Log: 활성" || record_warn "[$ALIAS] Binary Log: 비활성"
    fi

    # InnoDB
    print_section "  3. InnoDB 상태"
    DL=$(mysql_exec "$DB_HOST" "$DB_PORT" "SHOW GLOBAL STATUS LIKE 'Innodb_deadlocks';" | awk '{print $2}')
    RL=$(mysql_exec "$DB_HOST" "$DB_PORT" "SHOW STATUS LIKE 'Innodb_row_lock_current_waits';" | awk '{print $2}')
    BR=$(mysql_exec "$DB_HOST" "$DB_PORT" "SHOW STATUS LIKE 'Innodb_buffer_pool_reads';"          | awk '{print $2}')
    BQ=$(mysql_exec "$DB_HOST" "$DB_PORT" "SHOW STATUS LIKE 'Innodb_buffer_pool_read_requests';"  | awk '{print $2}')

    check_threshold "${DL:-0}" "$DEAD_LOCK_WARN" "10" "[$ALIAS] 데드락" "건"
    check_threshold "${RL:-0}" "10"              "50" "[$ALIAS] Row Lock" "건"
    if [[ -n "$BQ" && "$BQ" -gt 0 ]]; then
      HT=$(awk "BEGIN{printf \"%.1f\", (1-(${BR:-0}/$BQ))*100}")
      HI=$(printf "%.0f" "$HT")
      if   [[ $HI -lt $BUF_HIT_FAIL ]]; then record_fail "[$ALIAS] Buffer Pool Hit: ${HT}%"
      elif [[ $HI -lt $BUF_HIT_WARN ]]; then record_warn "[$ALIAS] Buffer Pool Hit: ${HT}%"
      else                                    record_ok   "[$ALIAS] Buffer Pool Hit: ${HT}%"
      fi
    fi

    SQ=$(mysql_exec "$DB_HOST" "$DB_PORT" "SHOW STATUS LIKE 'Slow_queries';" | awk '{print $2}')
    check_threshold "${SQ:-0}" "$SLOW_QUERY_WARN" "$((SLOW_QUERY_WARN*5))" "[$ALIAS] 슬로우 쿼리" "건"
  fi

  # ── ② SSH: 로컬 전용 ────────────────────────────────────────────────
  print_section "  4. 로컬 리소스 (SSH)"
  ssh_reachable "$SERVER" || { record_warn "[$ALIAS] SSH 불가"; continue; }
  RAW=$(ssh_run_script "$SERVER" "$REMOTE_AGENT_SCRIPT" "--role mysql" 2>/dev/null)
  [[ -z "$RAW" ]] && { record_warn "[$ALIAS] 에이전트 응답 없음"; continue; }
  _get() { echo "$RAW" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null || echo ""; }

  check_threshold "$(_get "['system']['cpu_pct']")"            70 90           "[$ALIAS] CPU" "%"
  check_threshold "$(_get "['system']['mem_pct']")"            75 90           "[$ALIAS] 메모리" "%"
  check_threshold "$(_get "['system']['disk_root_pct']")"      "$DISK_WARN" "$DISK_FAIL" "[$ALIAS] 디스크(/)" "%"
  check_threshold "$(_get "['mysql_local']['disk_data_pct']")" "$DISK_WARN" "$DISK_FAIL" "[$ALIAS] 디스크(data)" "%"
  SVC=$(_get "['mysql_local']['svc_status']")
  [[ "$SVC" == "active" ]] && record_ok "[$ALIAS] MySQL 서비스: active" || record_fail "[$ALIAS] MySQL 서비스: ${SVC}"
  SLOW_SZ=$(_get "['mysql_local']['slow_log_size_mb']")
  BINLOG_SZ=$(_get "['mysql_local']['binlog_total_mb']")
  [[ "${SLOW_SZ:-0}"   -gt 1024 ]] && record_warn "[$ALIAS] 슬로우 로그: ${SLOW_SZ}MB"
  [[ -n "$BINLOG_SZ"             ]] && print_info  "[$ALIAS] Binlog: ${BINLOG_SZ}MB"
  OOM=$(_get "['system']['oom_60m']")
  [[ "${OOM:-0}" -gt 0 ]] && record_fail "[$ALIAS] OOM: ${OOM}건" || record_ok "[$ALIAS] OOM 없음"
  check_mysqld_exporter "$ALIAS"
  check_node_exporter "$ALIAS"
done

print_summary
