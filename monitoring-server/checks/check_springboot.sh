#!/bin/bash
# =============================================================================
# monitoring-server/checks/check_springboot.sh  v4
#
# 변경 내용:
#   - SPRING_ACTUATOR_HOSTS + 포트 방식 → SPRING_ACTUATOR_URLS (Nginx 프록시 경유)
#   - Actuator URL: http://운영IP:8080/actuator → https://Nginx/ops/actuator/spring-N/
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

HEAP_WARN=$SPRING_HEAP_WARN;         HEAP_FAIL=$SPRING_HEAP_FAIL
THREAD_WARN=$SPRING_THREAD_WARN;      THREAD_FAIL=$SPRING_THREAD_FAIL
CONN_POOL_WARN=$SPRING_POOL_WARN;    CONN_POOL_FAIL=$SPRING_POOL_FAIL
RESP_TIME_WARN=$SPRING_RESP_WARN;  RESP_TIME_FAIL=$SPRING_RESP_FAIL
ERROR_LOG_WARN=$SPRING_ERROR_LOG_WARN;   ERROR_LOG_FAIL=$SPRING_ERROR_LOG_FAIL
FD_WARN=$SPRING_FD_WARN;           FD_FAIL=$SPRING_FD_FAIL

init_log "springboot_check"
print_header "Spring Boot 점검 (SSH + Nginx 프록시) | $DATE_LABEL"

for i in "${!SPRING_SERVERS[@]}"; do
  SERVER="${SPRING_SERVERS[$i]}"
  ACTUATOR_BASE="${SPRING_ACTUATOR_URLS[$i]}"   # Nginx 프록시 URL
  ALIAS=$(get_alias "$SERVER")
  HOST=$(get_host "$SERVER")

  print_section "[ $ALIAS ($HOST) ]"
  print_info "Actuator 경로: $ACTUATOR_BASE"

  # ── ① SSH: 로컬 전용 정보 ────────────────────────────────────────────
  print_section "  1. 로컬 리소스 (SSH)"
  if ! ssh_reachable "$SERVER"; then
    record_fail "[$ALIAS] SSH 접속 불가"
    continue
  fi

  RAW=$(ssh_run_script "$SERVER" "$REMOTE_AGENT_SCRIPT" "--role springboot" 2>/dev/null)
  if [[ -z "$RAW" ]]; then
    record_warn "[$ALIAS] 로컬 에이전트 응답 없음"
  else
    _get() { echo "$RAW" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null || echo ""; }

    check_threshold "$(_get "['system']['cpu_pct']")"    70 90 "[$ALIAS] CPU" "%"
    check_threshold "$(_get "['system']['mem_pct']")"    75 90 "[$ALIAS] 메모리" "%"
    check_threshold "$(_get "['system']['disk_root_pct']")" 70 85 "[$ALIAS] 디스크(/)" "%"
    OOM_K=$(_get "['system']['oom_60m']")
    [[ "${OOM_K:-0}" -gt 0 ]] && record_fail "[$ALIAS] OOM Killer: ${OOM_K}건" || record_ok "[$ALIAS] OOM 없음"

    APP_PID=$(_get "['springboot']['pid']")
    UPTIME=$(_get "['springboot']['uptime_min']")
    RSS=$(_get "['springboot']['rss_mb']")
    FD_PCT=$(_get "['springboot']['fd_pct']")
    FD_CNT=$(_get "['springboot']['fd_count']")
    FD_LIM=$(_get "['springboot']['fd_limit']")
    ERR_5M=$(_get "['springboot']['error_5m']")
    WARN_5M=$(_get "['springboot']['warn_5m']")
    OOM_APP=$(_get "['springboot']['oom_total']")
    SOE=$(_get "['springboot']['soe_total']")
    ERR_TYPES=$(_get "['springboot']['error_types']")
    FULL_GC=$(_get "['springboot']['full_gc']")
    DISK_APP=$(_get "['springboot']['disk_applog_pct']")

    [[ -n "$APP_PID" ]] \
      && record_ok "[$ALIAS] 앱 프로세스 (PID:$APP_PID, ${UPTIME}분, RSS:${RSS}MB)" \
      || record_fail "[$ALIAS] 앱 프로세스 없음"

    check_threshold "${FD_PCT:-0}"   "$FD_WARN"        "$FD_FAIL"        "[$ALIAS] FD (${FD_CNT}/${FD_LIM})" "%"
    check_threshold "${ERR_5M:-0}"   "$ERROR_LOG_WARN"  "$ERROR_LOG_FAIL"  "[$ALIAS] ERROR 로그(5분)" "건"
    check_threshold "${DISK_APP:-0}" 70 85 "[$ALIAS] 디스크(앱로그)" "%"
    [[ "${WARN_5M:-0}"  -gt 50 ]] && record_warn "[$ALIAS] WARN 로그: ${WARN_5M}건(5분)"
    [[ "${OOM_APP:-0}"  -gt 0  ]] && record_fail "[$ALIAS] OutOfMemoryError: ${OOM_APP}건" || record_ok "[$ALIAS] OOM 없음"
    [[ "${SOE:-0}"      -gt 0  ]] && record_warn "[$ALIAS] StackOverflowError: ${SOE}건"
    [[ "${FULL_GC:-0}"  -gt 5  ]] && record_warn "[$ALIAS] Full GC: ${FULL_GC}회"
    [[ -n "$ERR_TYPES"         ]] && print_info "[$ALIAS] 예외 유형: $ERR_TYPES"
  fi

  # ── ② Nginx 프록시 경유: Actuator HTTP ───────────────────────────────
  print_section "  2. Actuator 점검 (Nginx 프록시 경유)"

  # 포트 직접 확인 대신 Nginx를 통한 HTTP 응답으로 생존 확인
  HEALTH_JSON=$(curl -sk --max-time 5 "${ACTUATOR_BASE}/health" 2>/dev/null)
  if [[ -z "$HEALTH_JSON" ]]; then
    record_fail "[$ALIAS] Actuator 응답 없음 (Nginx 프록시: ${ACTUATOR_BASE}/health)"
    print_info  "[$ALIAS] Nginx 프록시 설정 및 Spring Boot 기동 여부 확인"
  else
    OVERALL=$(echo "$HEALTH_JSON" | python3 -c "
import sys,json; d=json.load(sys.stdin); print(d.get('status','UNKNOWN'))" 2>/dev/null)
    [[ "$OVERALL" == "UP" ]] \
      && record_ok   "[$ALIAS] Actuator: UP" \
      || record_fail "[$ALIAS] Actuator: ${OVERALL:-UNKNOWN}"

    for comp in db redis diskSpace; do
      ST=$(echo "$HEALTH_JSON" | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(d.get('components',{}).get('$comp',{}).get('status','N/A'))" 2>/dev/null)
      [[ "$ST" == "UP"  ]] && record_ok  "[$ALIAS]  [$comp]: UP"
      [[ "$ST" == "N/A" ]] && print_info "[$ALIAS]  [$comp]: 미설정"
      [[ "$ST" != "UP" && "$ST" != "N/A" ]] && record_fail "[$ALIAS]  [$comp]: $ST"
    done
  fi

  get_metric() {
    curl -sk --max-time 3 "${ACTUATOR_BASE}/metrics/$1" 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['measurements'][0]['value'])" 2>/dev/null || echo ""
  }

  HEAP_USED=$(get_metric "jvm.memory.used?tag=area:heap")
  HEAP_MAX=$(get_metric  "jvm.memory.max?tag=area:heap")
  if [[ -n "$HEAP_USED" && -n "$HEAP_MAX" && "${HEAP_MAX%.*}" -gt 0 ]]; then
    HEAP_PCT=$(awk "BEGIN{printf \"%.0f\", ($HEAP_USED/$HEAP_MAX)*100}")
    HEAP_MB=$(awk  "BEGIN{printf \"%.0f\", $HEAP_USED/1048576}")
    HMAX_MB=$(awk  "BEGIN{printf \"%.0f\", $HEAP_MAX/1048576}")
    check_threshold "$HEAP_PCT" "$HEAP_WARN" "$HEAP_FAIL" "[$ALIAS] JVM Heap (${HEAP_MB}/${HMAX_MB}MB)" "%"
  fi

  THREADS=$(get_metric "jvm.threads.live")
  [[ -n "$THREADS" ]] && check_threshold "$(printf "%.0f" "$THREADS")" \
    "$THREAD_WARN" "$THREAD_FAIL" "[$ALIAS] JVM 스레드" "개"

  PA=$(get_metric "hikaricp.connections.active")
  PM=$(get_metric "hikaricp.connections.max")
  if [[ -n "$PA" && -n "$PM" && "${PM%.*}" -gt 0 ]]; then
    check_threshold "$(awk "BEGIN{printf \"%.0f\", ($PA/$PM)*100}")" \
      "$CONN_POOL_WARN" "$CONN_POOL_FAIL" "[$ALIAS] HikariCP (${PA%.*}/${PM%.*})" "%"
  fi

  RC=$(get_metric "http.server.requests?statistic=count")
  RT=$(get_metric "http.server.requests?statistic=totalTime")
  if [[ -n "$RC" && "${RC%.*}" -gt 0 ]]; then
    check_threshold "$(awk "BEGIN{printf \"%.0f\", (${RT:-0}/$RC)*1000}")" \
      "$RESP_TIME_WARN" "$RESP_TIME_FAIL" "[$ALIAS] 평균 응답시간" "ms"
  fi

  check_node_exporter "$ALIAS"
done

print_summary
