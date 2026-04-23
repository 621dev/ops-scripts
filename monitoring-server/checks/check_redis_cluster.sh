#!/bin/bash
# =============================================================================
# monitoring-server/checks/check_redis_cluster.sh  v4
#
# 변경 내용:
#   - Redis 직접 접근(192.168.10.30:6379) → SSH 터널(127.0.0.1:16379~16381) 경유
#   - REDIS_CLUSTER_NODES 값이 inventory.sh에서 이미 로컬 포트로 설정됨
#   - 터널 생존 여부를 점검 시작 시 확인
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

MEM_WARN=$REDIS_MEM_WARN;          MEM_FAIL=$REDIS_MEM_FAIL
CONN_WARN=$REDIS_CONN_WARN;       CONN_FAIL=$REDIS_CONN_FAIL
BLOCKED_WARN=$REDIS_BLOCKED_WARN
SLOWLOG_WARN=$REDIS_SLOWLOG_WARN
QUEUE_LEN_WARN=$QUEUE_LEN_WARN; QUEUE_LEN_FAIL=$QUEUE_LEN_FAIL
RDB_AGE_WARN=$REDIS_RDB_AGE_WARN

init_log "redis_cluster_check"
print_header "Redis 클러스터 점검 (SSH 터널 경유) | $DATE_LABEL"

redis_cmd() {
  local node="$1"; shift
  local h p; IFS=':' read -r h p <<< "$node"
  if [[ -n "$REDIS_AUTH" ]]; then
    redis-cli -h "$h" -p "$p" --no-auth-warning -a "$REDIS_AUTH" "$@" 2>/dev/null || true
  else
    redis-cli -h "$h" -p "$p" "$@" 2>/dev/null || true
  fi
}
parse_info() { echo "$1" | grep "^$2:" | cut -d: -f2- | tr -d '\r '; }

# ── 터널 상태 사전 확인 ──────────────────────────────────────────────────
print_section "0. SSH 터널 상태 확인"
TUNNEL_OK=true
for entry in "${REDIS_TUNNEL_MAP[@]}"; do
  IFS=':' read -r _ _ alias _ local_port <<< "$entry"
  if check_tunnel_alive "$local_port" "redis[$alias]"; then
    record_ok "터널 redis[$alias] → 127.0.0.1:${local_port} 응답"
  else
    record_fail "터널 redis[$alias] → 127.0.0.1:${local_port} 응답 없음"
    TUNNEL_OK=false
  fi
done
if [[ "$TUNNEL_OK" == "false" ]]; then
  print_warn "일부 터널이 열려있지 않습니다. run_all_checks.sh 를 통해 실행하거나"
  print_warn "open_tunnels redis 를 먼저 실행하세요."
fi

# ── ① 모니터링 서버 직접: Redis 쿼리 (터널 경유) ───────────────────────
print_section "1. PING 확인"
LIVE_NODES=()
for node in "${REDIS_CLUSTER_NODES[@]}"; do
  PONG=$(redis_cmd "$node" PING)
  if [[ "$PONG" == "PONG" ]]; then
    record_ok "[$node] PING → PONG"
    LIVE_NODES+=("$node")
  else
    record_fail "[$node] PING 응답 없음 (터널 확인 필요)"
  fi
done

[[ ${#LIVE_NODES[@]} -eq 0 ]] && { record_fail "응답 노드 없음"; print_summary; exit 2; }
PRIMARY="${LIVE_NODES[0]}"

print_section "2. 클러스터 상태"
CLUSTER_INFO=$(redis_cmd "$PRIMARY" CLUSTER INFO)
if [[ -n "$CLUSTER_INFO" ]]; then
  CS=$(parse_info "$CLUSTER_INFO" "cluster_state")
  SF=$(parse_info "$CLUSTER_INFO" "cluster_slots_fail")
  SP=$(parse_info "$CLUSTER_INFO" "cluster_slots_pfail")
  SA=$(parse_info "$CLUSTER_INFO" "cluster_slots_assigned")
  SO=$(parse_info "$CLUSTER_INFO" "cluster_slots_ok")
  KN=$(parse_info "$CLUSTER_INFO" "cluster_known_nodes")

  [[ "$CS" == "ok" ]] && record_ok "클러스터 상태: ok" || record_fail "클러스터 상태: $CS"
  [[ "${SF:-0}" -eq 0 ]] && record_ok "FAIL 슬롯 없음" || record_fail "FAIL 슬롯: ${SF}개"
  [[ "${SP:-0}" -gt 0 ]] && record_warn "PFAIL 슬롯: ${SP}개"
  print_info "슬롯: ${SA}/16384 (정상:${SO} PFAIL:${SP} FAIL:${SF})  노드: ${KN}"

  redis_cmd "$PRIMARY" CLUSTER NODES | while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ADDR=$(echo "$line" | awk '{print $2}' | cut -d'@' -f1)
    FLAGS=$(echo "$line" | awk '{print $3}')
    SLOTS=$(echo "$line" | awk '{print $9}')
    if echo "$FLAGS" | grep -qE "fail|noaddr"; then print_fail "  $ADDR  flags:$FLAGS"
    elif echo "$FLAGS" | grep -q "master";      then print_ok   "  $ADDR  master  slots:$SLOTS"
    else                                              print_ok   "  $ADDR  replica"
    fi
  done
else
  record_warn "CLUSTER INFO 조회 실패"
fi

print_section "3. 노드별 통계"
NOW_E=$(date +%s)
for node in "${LIVE_NODES[@]}"; do
  echo -e "  ${BOLD}[ $node ]${NC}"
  INFO=$(redis_cmd "$node" INFO all)
  [[ -z "$INFO" ]] && { record_fail "[$node] INFO 실패"; continue; }
  pi() { parse_info "$INFO" "$1"; }

  ROLE=$(pi role); UM=$(pi used_memory); MM=$(pi maxmemory)
  CONN=$(pi connected_clients); BLOCKED=$(pi blocked_clients)
  EVICTED=$(pi evicted_keys)
  KH=$(pi keyspace_hits); KM=$(pi keyspace_misses)
  RSTATUS=$(pi rdb_last_bgsave_status); RLAST=$(pi rdb_last_save_time)
  RJ=$(pi rejected_connections)
  UM_MB=$(awk "BEGIN{printf \"%.1f\", ${UM:-0}/1048576}")

  print_info "역할:$ROLE  메모리:${UM_MB}MB"
  if [[ -n "$MM" && "$MM" -gt 0 ]]; then
    check_threshold "$(awk "BEGIN{printf \"%.0f\", (${UM:-0}/$MM)*100}")" \
      "$MEM_WARN" "$MEM_FAIL" "  [$node] 메모리" "%"
  else
    print_info "  [$node] 메모리: ${UM_MB}MB (maxmemory 미설정)"
  fi
  check_threshold "${CONN:-0}"    "$CONN_WARN"    "$CONN_FAIL"           "  [$node] 연결" "개"
  check_threshold "${BLOCKED:-0}" "$BLOCKED_WARN" "$((BLOCKED_WARN*5))"  "  [$node] Blocked" "개"
  [[ "${EVICTED:-0}" -gt 0 ]] && record_warn "  [$node] Evicted: ${EVICTED}개" || record_ok "  [$node] Eviction 없음"
  [[ "${RJ:-0}"      -gt 0 ]] && record_warn "  [$node] Rejected: ${RJ}건"

  TH=$(( ${KH:-0} + ${KM:-0} ))
  [[ $TH -gt 0 ]] && {
    HR=$(awk "BEGIN{printf \"%.1f\", (${KH:-0}/$TH)*100}")
    [[ $(printf "%.0f" "$HR") -lt 80 ]] \
      && record_warn "  [$node] Hit Rate: ${HR}%" || record_ok "  [$node] Hit Rate: ${HR}%"
  }

  if [[ -n "$RLAST" && "$RLAST" -gt 0 ]]; then
    AGE=$(( NOW_E - RLAST ))
    RDT=$(date -d "@$RLAST" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "epoch:$RLAST")
    [[ "$RSTATUS" == "ok" && $AGE -le $RDB_AGE_WARN ]] \
      && record_ok "  [$node] RDB ($RDT)" || record_warn "  [$node] RDB 오래됨 ($RDT, ${AGE}초 전)"
  fi
  [[ "$ROLE" == "slave" ]] && {
    LS=$(pi master_link_status)
    [[ "$LS" == "up" ]] && record_ok "  [$node] 복제: up" || record_fail "  [$node] 복제: $LS"
  }
done

print_section "4. 메시지 큐 적체"
for node in "${LIVE_NODES[@]}"; do
  for key in "${QUEUE_KEYS[@]}"; do
    KT=$(redis_cmd "$node" TYPE "$key")
    case "$KT" in
      list)   LEN=$(redis_cmd "$node" LLEN "$key")
              check_threshold "${LEN:-0}" "$QUEUE_LEN_WARN" "$QUEUE_LEN_FAIL" "[$node] $key" "건" ;;
      stream) LEN=$(redis_cmd "$node" XLEN "$key")
              check_threshold "${LEN:-0}" "$QUEUE_LEN_WARN" "$QUEUE_LEN_FAIL" "[$node] $key (Stream)" "건" ;;
      none)   print_info "  [$node] $key: 없음" ;;
    esac
  done
done

print_section "5. SlowLog"
for node in "${LIVE_NODES[@]}"; do
  SL=$(redis_cmd "$node" SLOWLOG LEN || echo 0)
  [[ "$SL" -gt "$SLOWLOG_WARN" ]] \
    && record_warn "[$node] SlowLog: ${SL}건" || record_ok "[$node] SlowLog: ${SL}건"
done

# ── ② SSH: 로컬 전용 ────────────────────────────────────────────────────
print_section "6. 로컬 리소스 (SSH)"
for SERVER in "${REDIS_SERVERS[@]}"; do
  ALIAS=$(get_alias "$SERVER"); HOST=$(get_host "$SERVER")
  ssh_reachable "$SERVER" || { record_warn "[$ALIAS] SSH 불가"; continue; }
  RAW=$(ssh_run_script "$SERVER" "$REMOTE_AGENT_SCRIPT" "--role redis" 2>/dev/null)
  [[ -z "$RAW" ]] && { record_warn "[$ALIAS] 에이전트 응답 없음"; continue; }
  _get() { echo "$RAW" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null || echo ""; }

  check_threshold "$(_get "['system']['cpu_pct']")"          70 90 "[$ALIAS] CPU" "%"
  check_threshold "$(_get "['system']['mem_pct']")"          75 90 "[$ALIAS] 메모리" "%"
  check_threshold "$(_get "['system']['disk_root_pct']")"    70 85 "[$ALIAS] 디스크(/)" "%"
  check_threshold "$(_get "['redis_local']['disk_data_pct']")" 70 85 "[$ALIAS] 디스크(data)" "%"
  SVC=$(_get "['redis_local']['svc_status']")
  [[ "$SVC" == "active" ]] && record_ok "[$ALIAS] 서비스: active" || record_fail "[$ALIAS] 서비스: ${SVC}"
  THP=$(_get "['redis_local']['thp_status']")
  [[ "$THP" == "never" ]] && record_ok "[$ALIAS] THP: never" || record_warn "[$ALIAS] THP: ${THP} (never 권장)"
  OOM=$(_get "['system']['oom_60m']")
  [[ "${OOM:-0}" -gt 0 ]] && record_fail "[$ALIAS] OOM: ${OOM}건"
  check_redis_exporter "$ALIAS"
  check_node_exporter "$ALIAS"
done

print_summary
