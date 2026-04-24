#!/bin/bash
# =============================================================================
# monitoring-server/generate_report.sh
# 점검 결과를 Claude API로 분석하여 마크다운 보고서 생성
#
# 사용법:
#   bash generate_report.sh                        # 점검 실행 후 보고서 생성
#   bash generate_report.sh --role redis           # 특정 역할만
#   bash generate_report.sh --file /tmp/result.txt # 기존 결과 파일로 보고서만 생성
#   bash generate_report.sh --no-run               # 점검 생략, 최신 로그로 보고서만 생성
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/utils.sh"
source "$SCRIPT_DIR/common/inventory.sh"

# ── 설정 ──────────────────────────────────────────────────────────────────────
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
MODEL="claude-sonnet-4-20250514"
MAX_TOKENS=4000
REPORT_DIR="${MONITOR_LOG_DIR}/reports"
TIMESTAMP_NOW=$(date '+%Y%m%d_%H%M%S')
DATE_KR=$(date '+%Y년 %m월 %d일 %H:%M')

# ── 인자 파싱 ─────────────────────────────────────────────────────────────────
TARGET_ROLE="all"
INPUT_FILE=""
NO_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)   TARGET_ROLE="$2"; shift 2 ;;
    --file)   INPUT_FILE="$2"; shift 2 ;;
    --no-run) NO_RUN=true; shift ;;
    --help)
      echo "사용법: $0 [--role all|nginx|springboot|redis|mysql] [--file 결과파일] [--no-run]"
      exit 0 ;;
    *) shift ;;
  esac
done

# API 키 확인
if [[ -z "$ANTHROPIC_API_KEY" ]]; then
  echo "[ERROR] ANTHROPIC_API_KEY 환경변수가 설정되지 않았습니다."
  echo "  export ANTHROPIC_API_KEY='your-api-key'"
  exit 1
fi

mkdir -p "$REPORT_DIR"

RESULT_FILE="/tmp/ops_check_result_${TIMESTAMP_NOW}.txt"
REPORT_FILE="${REPORT_DIR}/report_${TIMESTAMP_NOW}.md"

# ── Step 1: 점검 실행 ─────────────────────────────────────────────────────────
if [[ -n "$INPUT_FILE" ]]; then
  # 외부 파일 지정
  RESULT_FILE="$INPUT_FILE"
  echo "기존 결과 파일 사용: $INPUT_FILE"

elif $NO_RUN; then
  # 최신 로그 파일 사용
  LATEST_LOG=$(ls -t "${MONITOR_LOG_DIR}"/*.log 2>/dev/null | head -1)
  if [[ -z "$LATEST_LOG" ]]; then
    echo "[ERROR] 로그 파일 없음: $MONITOR_LOG_DIR"
    exit 1
  fi
  RESULT_FILE="$LATEST_LOG"
  echo "최신 로그 파일 사용: $LATEST_LOG"

else
  # 점검 실행 후 결과 저장
  echo "점검 실행 중..."
  trap 'close_tunnels all' EXIT INT TERM

  case "$TARGET_ROLE" in
    redis)      open_tunnels redis ;;
    mysql)      open_tunnels mysql ;;
    all|*)      open_tunnels all ;;
  esac

  bash "$SCRIPT_DIR/run_all_checks.sh" --role "$TARGET_ROLE" \
    2>&1 | tee "$RESULT_FILE"

  # 색상 코드 제거 (API 전송용)
  sed -i 's/\x1b\[[0-9;]*m//g' "$RESULT_FILE"
fi

# ── Step 2: 결과 요약 추출 ────────────────────────────────────────────────────
# FAIL/WARN 항목만 추출하여 API 전송 크기 최적화
FAIL_LINES=$(grep "\[FAIL\]" "$RESULT_FILE" 2>/dev/null || true)
WARN_LINES=$(grep "\[WARN\]" "$RESULT_FILE" 2>/dev/null || true)
SUMMARY_LINE=$(grep -A3 "점검 요약" "$RESULT_FILE" 2>/dev/null | tail -5 || true)

# 전체 결과 (색상 코드 제거)
FULL_RESULT=$(cat "$RESULT_FILE" | sed 's/\x1b\[[0-9;]*m//g' | head -300)

# ── Step 3: Claude API 호출 ────────────────────────────────────────────────────
echo ""
echo "Claude API로 보고서 생성 중..."

# 프롬프트 구성
PROMPT="당신은 서버 운영 전문가입니다. 아래는 메시지 서비스 인프라 자동 점검 결과입니다.

인프라 구성:
- Nginx 1대 (리버스 프록시)
- Spring Boot 2대 (메시지 처리 애플리케이션)
- Redis Cluster 3노드 (메시지 큐)
- MySQL 2대 (Primary-Replica 복제)

점검 일시: ${DATE_KR}
점검 대상: ${TARGET_ROLE}

=== 점검 결과 ===
${FULL_RESULT}

위 점검 결과를 분석하여 아래 형식의 마크다운 보고서를 작성해주세요:

1. **전체 요약** - 정상/경고/장애 건수와 전반적인 상태 한 줄 평가
2. **장애 항목 분석** - [FAIL] 항목별 원인과 즉시 조치 방법
3. **경고 항목 분석** - [WARN] 항목별 원인과 권장 조치
4. **조치 우선순위** - 긴급/주의/모니터링 순으로 정리
5. **정상 항목** - 정상 동작 중인 주요 항목 요약

보고서는 실무자가 바로 조치할 수 있도록 구체적으로 작성해주세요."

# JSON 이스케이프
PROMPT_ESCAPED=$(echo "$PROMPT" | python3 -c "
import sys, json
content = sys.stdin.read()
print(json.dumps(content))
")

# API 호출
API_RESPONSE=$(curl -s \
  --max-time 60 \
  -X POST https://api.anthropic.com/v1/messages \
  -H "x-api-key: ${ANTHROPIC_API_KEY}" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "{
    \"model\": \"${MODEL}\",
    \"max_tokens\": ${MAX_TOKENS},
    \"messages\": [{
      \"role\": \"user\",
      \"content\": ${PROMPT_ESCAPED}
    }]
  }" 2>/dev/null)

# API 응답 파싱
if [[ -z "$API_RESPONSE" ]]; then
  echo "[ERROR] API 응답 없음 (네트워크 또는 API 키 확인)"
  exit 1
fi

API_ERROR=$(echo "$API_RESPONSE" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d.get('error',{}).get('message',''))
" 2>/dev/null)

if [[ -n "$API_ERROR" ]]; then
  echo "[ERROR] API 오류: $API_ERROR"
  exit 1
fi

REPORT_CONTENT=$(echo "$API_RESPONSE" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d['content'][0]['text'])
" 2>/dev/null)

# ── Step 4: 마크다운 보고서 저장 ──────────────────────────────────────────────
cat > "$REPORT_FILE" << MDEOF
# 인프라 운영 점검 보고서

- **점검 일시**: ${DATE_KR}
- **점검 대상**: ${TARGET_ROLE}
- **보고서 생성**: $(date '+%Y-%m-%d %H:%M:%S')

---

${REPORT_CONTENT}

---

## 원본 점검 결과

\`\`\`
$(cat "$RESULT_FILE" | sed 's/\x1b\[[0-9;]*m//g' | head -200)
\`\`\`

---
*본 보고서는 자동 생성되었습니다.*
MDEOF

echo ""
echo "✔ 보고서 생성 완료: $REPORT_FILE"
echo ""

# 보고서 내용 출력
cat "$REPORT_FILE"
