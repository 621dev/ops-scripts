#!/bin/bash
# =============================================================================
# monitoring-server/generate_report.sh
# 점검 결과를 Claude로 분석하여 마크다운 보고서 생성 + Slack 발송
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

# Claude 호출 방식
# "claude-code" : Claude Code CLI 사용 (구독제, claude login 필요)
# "api"         : Anthropic API 사용 (ANTHROPIC_API_KEY 환경변수 필요)
CLAUDE_MODE="${CLAUDE_MODE:-claude-code}"

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

# ── 사전 확인 ─────────────────────────────────────────────────────────────────
if [[ "$CLAUDE_MODE" == "claude-code" ]]; then
  if ! command -v claude &>/dev/null; then
    echo "[ERROR] Claude Code 미설치: npm install -g @anthropic-ai/claude-code"
    exit 1
  fi
elif [[ "$CLAUDE_MODE" == "api" ]]; then
  if [[ -z "$ANTHROPIC_API_KEY" ]]; then
    echo "[ERROR] API 모드: ANTHROPIC_API_KEY 환경변수가 필요합니다."
    echo "  export ANTHROPIC_API_KEY='sk-ant-...'"
    echo "  또는 CLAUDE_MODE=claude-code 로 변경하세요."
    exit 1
  fi
else
  echo "[ERROR] CLAUDE_MODE 값이 올바르지 않습니다: ${CLAUDE_MODE}"
  echo "  api 또는 claude-code 중 선택하세요."
  exit 1
fi

mkdir -p "$REPORT_DIR"

RESULT_FILE="/tmp/ops_check_result_${TIMESTAMP_NOW}.txt"
REPORT_FILE="${REPORT_DIR}/report_${TIMESTAMP_NOW}.md"

# ── Step 1: 점검 실행 ─────────────────────────────────────────────────────────
if [[ -n "$INPUT_FILE" ]]; then
  RESULT_FILE="$INPUT_FILE"
  echo "기존 결과 파일 사용: $INPUT_FILE"

elif $NO_RUN; then
  LATEST_LOG=$(ls -t "${MONITOR_LOG_DIR}"/*.log 2>/dev/null | head -1)
  if [[ -z "$LATEST_LOG" ]]; then
    echo "[ERROR] 로그 파일 없음: $MONITOR_LOG_DIR"
    exit 1
  fi
  RESULT_FILE="$LATEST_LOG"
  echo "최신 로그 파일 사용: $LATEST_LOG"

else
  echo "점검 실행 중..."
  trap 'close_tunnels all' EXIT INT TERM

  case "$TARGET_ROLE" in
    redis)      open_tunnels redis ;;
    mysql)      open_tunnels mysql ;;
    springboot) : ;;
    nginx)      : ;;
    all|*)      open_tunnels all ;;
  esac

  bash "$SCRIPT_DIR/run_all_checks.sh" --role "$TARGET_ROLE" \
    2>&1 | tee "$RESULT_FILE"

  sed -i 's/\x1b\[[0-9;]*m//g' "$RESULT_FILE"
fi

# ── Step 2: 결과 추출 ─────────────────────────────────────────────────────────
FULL_RESULT=$(cat "$RESULT_FILE" | sed 's/\x1b\[[0-9;]*m//g' | head -300)

# ── Step 3: Claude 호출 ───────────────────────────────────────────────────────
echo ""
echo "보고서 생성 중... (모드: ${CLAUDE_MODE})"

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

if [[ "$CLAUDE_MODE" == "api" ]]; then
  PROMPT_ESCAPED=$(echo "$PROMPT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")

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

  if [[ -z "$API_RESPONSE" ]]; then
    echo "[ERROR] API 응답 없음 (네트워크 또는 API 키 확인)"
    exit 1
  fi

  API_ERROR=$(echo "$API_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',{}).get('message',''))" 2>/dev/null)
  if [[ -n "$API_ERROR" ]]; then
    echo "[ERROR] API 오류: $API_ERROR"
    exit 1
  fi

  REPORT_CONTENT=$(echo "$API_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['content'][0]['text'])" 2>/dev/null)

elif [[ "$CLAUDE_MODE" == "claude-code" ]]; then
  REPORT_CONTENT=$(claude --print "$PROMPT" 2>/dev/null)
fi

if [[ -z "$REPORT_CONTENT" ]]; then
  echo "[ERROR] 보고서 생성 실패 (Claude 응답 없음)"
  exit 1
fi

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

# ── Step 5: Slack 발송 ────────────────────────────────────────────────────────
if [[ -n "$SLACK_WEBHOOK_URL" ]]; then
  echo ""
  echo "Slack 발송 중..."

  FAIL_COUNT=$(grep -c "\[FAIL\]" "$RESULT_FILE" 2>/dev/null || echo 0)
  WARN_COUNT=$(grep -c "\[WARN\]" "$RESULT_FILE" 2>/dev/null || echo 0)
  OK_COUNT=$(grep -c "\[OK\]"     "$RESULT_FILE" 2>/dev/null || echo 0)

  if   [[ $FAIL_COUNT -gt 0 ]]; then STATUS_EMOJI="🔴"; STATUS_TEXT="장애 발생"
  elif [[ $WARN_COUNT -gt 0 ]]; then STATUS_EMOJI="🟡"; STATUS_TEXT="경고"
  else                               STATUS_EMOJI="🟢"; STATUS_TEXT="정상"
  fi

  SLACK_BODY=$(python3 << PYEOF
import json

fail_lines = []
warn_lines = []
with open("${RESULT_FILE}") as f:
    for line in f:
        if "[FAIL]" in line: fail_lines.append(line.strip())
        elif "[WARN]" in line: warn_lines.append(line.strip())

fail_lines = fail_lines[:10]
warn_lines = warn_lines[:5]

detail = ""
if fail_lines:
    detail += "*장애 항목:*\n" + "\n".join(["• " + l for l in fail_lines]) + "\n"
if warn_lines:
    detail += "*경고 항목:*\n" + "\n".join(["• " + l for l in warn_lines])

payload = {
    "attachments": [{
        "color": "#e74c3c" if ${FAIL_COUNT} > 0 else "#f39c12" if ${WARN_COUNT} > 0 else "#2ecc71",
        "blocks": [
            {
                "type": "header",
                "text": {"type": "plain_text", "text": "${STATUS_EMOJI} 인프라 점검 결과 — ${STATUS_TEXT}"}
            },
            {
                "type": "section",
                "fields": [
                    {"type": "mrkdwn", "text": "*점검 일시*\n${DATE_KR}"},
                    {"type": "mrkdwn", "text": "*점검 대상*\n${TARGET_ROLE}"},
                    {"type": "mrkdwn", "text": "*정상*\n✅ ${OK_COUNT}건"},
                    {"type": "mrkdwn", "text": "*경고*\n⚠️ ${WARN_COUNT}건"},
                    {"type": "mrkdwn", "text": "*장애*\n❌ ${FAIL_COUNT}건"},
                ]
            },
            {
                "type": "section",
                "text": {"type": "mrkdwn", "text": detail if detail else "✅ 모든 항목 정상"}
            },
            {
                "type": "context",
                "elements": [{"type": "mrkdwn", "text": "보고서: ${REPORT_FILE}"}]
            }
        ]
    }]
}
print(json.dumps(payload))
PYEOF
)

  SLACK_RESPONSE=$(curl -s -X POST "$SLACK_WEBHOOK_URL" \
    -H "Content-type: application/json" \
    -d "$SLACK_BODY" 2>/dev/null)

  [[ "$SLACK_RESPONSE" == "ok" ]] \
    && echo "✔ Slack 메시지 발송 완료" \
    || echo "[WARN] Slack 발송 실패: $SLACK_RESPONSE"

# ── md 파일 업로드 ────────────────────────────────────────────────────────
  if [[ -n "$SLACK_BOT_TOKEN" && -f "$REPORT_FILE" ]]; then
    echo "Slack 파일 업로드 중..."

    FILE_SIZE=$(wc -c < "$REPORT_FILE")
    FILE_NAME=$(basename "$REPORT_FILE")

    # Step 1: 업로드 URL 발급
    URL_RESPONSE=$(curl -s \
      -X POST "https://slack.com/api/files.getUploadURLExternal?filename=${FILE_NAME}&length=${FILE_SIZE}" \
      -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" 2>/dev/null)

    UPLOAD_URL=$(echo "$URL_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('upload_url',''))" 2>/dev/null)
    FILE_ID=$(echo "$URL_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('file_id',''))" 2>/dev/null)

    if [[ -z "$UPLOAD_URL" || -z "$FILE_ID" ]]; then
      echo "[WARN] 업로드 URL 발급 실패: $(echo "$URL_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',''))" 2>/dev/null)"
    else
      # Step 2: 파일 업로드
      curl -s -X POST "$UPLOAD_URL" \
        -F "file=@${REPORT_FILE}" 2>/dev/null

      # Step 3: 업로드 완료 처리
      COMPLETE_RES=$(curl -s \
        -X POST https://slack.com/api/files.completeUploadExternal \
        -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
        -H "Content-type: application/json" \
        -d "{
          \"files\":[{\"id\":\"${FILE_ID}\",\"title\":\"점검 보고서 ${DATE_KR}\"}],
          \"channel_id\":\"${SLACK_CHANNEL}\"
        }" 2>/dev/null)

      UPLOAD_OK=$(echo "$COMPLETE_RES" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok','false'))" 2>/dev/null)

      [[ "$UPLOAD_OK" == "True" || "$UPLOAD_OK" == "true" ]] \
        && echo "✔ 보고서 파일 업로드 완료" \
        || echo "[WARN] 파일 업로드 실패: $(echo "$COMPLETE_RES" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',''))" 2>/dev/null)"
    fi
  fi
fi
echo ""
echo "✔ 완료"
