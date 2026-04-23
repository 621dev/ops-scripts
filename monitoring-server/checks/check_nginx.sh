#!/bin/bash
# =============================================================================
# monitoring-server/checks/check_nginx.sh
# 모니터링 서버에서 실행 — Nginx 서버 점검
#
# 점검 방식:
#   [모니터링 서버 직접]  HTTP 응답, stub_status, SSL 인증서, 포트
#   [SSH → Nginx 서버]   프로세스, conf 문법, 에러 로그, 디스크, 커널
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

# ── 임계값 ────────────────────────────────────────────────────────────────
CONN_WARN=$NGINX_CONN_WARN;       CONN_FAIL=$NGINX_CONN_FAIL
ERROR_5XX_WARN=$NGINX_5XX_WARN;     ERROR_5XX_FAIL=$NGINX_5XX_FAIL
ERROR_LOG_WARN=$NGINX_ERROR_LOG_WARN;    ERROR_LOG_FAIL=$NGINX_ERROR_LOG_FAIL
UPSTREAM_HEALTH_CODE=$NGINX_UPSTREAM_HEALTH_CODE

init_log "nginx_check"
print_header "Nginx 점검 (모니터링 서버 → Nginx) | $DATE_LABEL"

for SERVER in "${NGINX_SERVERS[@]}"; do
  ALIAS=$(get_alias "$SERVER")
  HOST=$(get_host "$SERVER")

  print_section "[ $ALIAS ($HOST) ]"

  # ── ① SSH: 로컬 전용 정보 수집 ─────────────────────────────────────────
  print_section "  1. 로컬 리소스 (SSH)"
  if ! ssh_reachable "$SERVER"; then
    record_fail "[$ALIAS] SSH 접속 불가 ($HOST)"
    continue
  fi

  RAW=$(ssh_run_script "$SERVER" "$REMOTE_AGENT_SCRIPT" "--role nginx" 2>/dev/null)
  if [[ -z "$RAW" ]]; then
    record_warn "[$ALIAS] 로컬 에이전트 응답 없음"
  else
    # JSON 파싱 (python3)
    _get() { echo "$RAW" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null || echo ""; }

    # 시스템 리소스
    CPU_PCT=$(_get "['system']['cpu_pct']")
    MEM_PCT=$(_get "['system']['mem_pct']")
    DISK_ROOT=$(_get "['system']['disk_root_pct']")
    KERNEL_ERR=$(_get "['system']['kernel_errors_60m']")
    OOM=$(_get "['system']['oom_60m']")

    check_threshold "${CPU_PCT:-0}"    70 90 "[$ALIAS] CPU" "%"
    check_threshold "${MEM_PCT:-0}"    75 90 "[$ALIAS] 메모리" "%"
    check_threshold "${DISK_ROOT:-0}"  70 85 "[$ALIAS] 디스크(/)" "%"
    [[ "${OOM:-0}" -gt 0 ]] && record_fail "[$ALIAS] OOM Killer: ${OOM}건" \
                             || record_ok   "[$ALIAS] OOM 없음"
    check_threshold "${KERNEL_ERR:-0}" 1 5 "[$ALIAS] 커널 오류(60분)" "건"

    # Nginx 프로세스
    WORKER_CNT=$(_get "['nginx']['worker_count']")
    CONF_OK=$(_get "['nginx']['conf_ok']")
    CONF_MSG=$(_get "['nginx']['conf_msg']")
    ERR_5M=$(_get "['nginx']['error_log_5m']")
    ERR_PAT=$(_get "['nginx']['error_patterns']")
    DISK_LOG=$(_get "['nginx']['disk_log_pct']")

    [[ "${WORKER_CNT:-0}" -gt 0 ]] && record_ok "[$ALIAS] Nginx worker: ${WORKER_CNT}개" \
                                     || record_fail "[$ALIAS] Nginx worker 없음"
    [[ "$CONF_OK" == "True" || "$CONF_OK" == "true" ]] \
      && record_ok "[$ALIAS] nginx.conf 문법 정상" \
      || record_fail "[$ALIAS] nginx.conf 문법 오류: $CONF_MSG"
    check_threshold "${ERR_5M:-0}"   "$ERROR_LOG_WARN" "$ERROR_LOG_FAIL" "[$ALIAS] 에러 로그(5분)" "건"
    check_threshold "${DISK_LOG:-0}" 70 85 "[$ALIAS] 디스크(로그)" "%"
    [[ -n "$ERR_PAT" ]] && print_info "[$ALIAS] 에러 패턴: $ERR_PAT"
  fi

  # ── ② 모니터링 서버 직접: 네트워크 점검 ─────────────────────────────
  print_section "  2. 네트워크 점검 (모니터링 서버 직접)"

  check_port "$HOST" "$NGINX_HTTP_PORT" "[$ALIAS] HTTP(${NGINX_HTTP_PORT})"
  [[ -n "$NGINX_HTTPS_PORT" ]] && \
    check_port "$HOST" "$NGINX_HTTPS_PORT" "[$ALIAS] HTTPS(${NGINX_HTTPS_PORT})" || \
    print_info "[$ALIAS] HTTPS 미사용 (NGINX_HTTPS_PORT 미설정)"

  # stub_status (HTTP 포트 기반)
  STATUS_URL="http://${HOST}:${NGINX_HTTP_PORT}/nginx_status"
  STATUS_RAW=$(curl -s --max-time 5 "$STATUS_URL" 2>/dev/null)
  if [[ -n "$STATUS_RAW" ]]; then
    ACTIVE=$(echo "$STATUS_RAW"  | awk '/Active connections:/{print $3}')
    ACCEPTED=$(echo "$STATUS_RAW"| awk 'NR==3{print $1}')
    HANDLED=$(echo "$STATUS_RAW" | awk 'NR==3{print $2}')
    READING=$(echo "$STATUS_RAW" | awk '/Reading:/{print $2}')
    WRITING=$(echo "$STATUS_RAW" | awk '/Writing:/{print $4}')
    WAITING=$(echo "$STATUS_RAW" | awk '/Waiting:/{print $6}')

    check_threshold "${ACTIVE:-0}" "$CONN_WARN" "$CONN_FAIL" "[$ALIAS] 활성 연결" "개"
    print_info "[$ALIAS] Reading:${READING} Writing:${WRITING} Waiting:${WAITING}"
    if [[ -n "$ACCEPTED" && -n "$HANDLED" ]]; then
      DROPPED=$(( ACCEPTED - HANDLED ))
      [[ $DROPPED -gt 0 ]] \
        && record_warn "[$ALIAS] Drop 연결: ${DROPPED}건" \
        || record_ok   "[$ALIAS] Drop 연결 없음"
    fi
  else
    record_warn "[$ALIAS] stub_status 응답 없음 (http://${HOST}/nginx_status)"
  fi

  # 업스트림 헬스체크
  check_http "http://${HOST}/health" "[$ALIAS] 업스트림 헬스" "$UPSTREAM_HEALTH_CODE"

  # SSL 인증서 만료 (HTTPS 사용 시에만)
  if [[ -n "$NGINX_HTTPS_PORT" ]]; then
    require_cmd openssl && {
      EXPIRE_STR=$(echo | openssl s_client -connect "${HOST}:${NGINX_HTTPS_PORT}" \
        -servername "$HOST" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
      if [[ -n "$EXPIRE_STR" ]]; then
        EXPIRE_EPOCH=$(date -d "$EXPIRE_STR" +%s 2>/dev/null || echo 0)
        DAYS_LEFT=$(( (EXPIRE_EPOCH - $(date +%s)) / 86400 ))
      if   [[ $DAYS_LEFT -le 7  ]]; then record_fail "[$ALIAS] SSL 만료 임박: ${DAYS_LEFT}일"
      elif [[ $DAYS_LEFT -le 30 ]]; then record_warn "[$ALIAS] SSL 만료 예정: ${DAYS_LEFT}일"
      else                               record_ok   "[$ALIAS] SSL 유효: ${DAYS_LEFT}일"
      fi
    else
      record_warn "[$ALIAS] SSL 인증서 조회 실패"
    fi
  }
  fi   # NGINX_HTTPS_PORT 체크 종료

  # Node Exporter (모니터링 서버에서 직접 포트 확인)
  check_node_exporter "$ALIAS"
done

print_summary
