#!/usr/bin/env bash
# monitor.sh — 미션 6: 프로세스/시스템 리소스 트러블슈팅 관제 스크립트
#
# 미션 5 → 6 변경 요지 (관점 자체가 다름)
#   - 미션 5: 건강한 프로세스의 *정기 관제* (cron 매분, 시스템 전체 임계)
#   - 미션 6: 장애 재현 구간의 *시계열 부검* (대화형 / `watch -n 2`, 프로세스 임계)
#
# 책임 (미션 6):
#   1) Health Check        — agent-leak-app PID + 15034 LISTEN (실패 시 exit 1)
#   2) 상태 점검            — UFW 활성 여부 (실패 시 [WARNING], 종료 X)
#   3) 자원 수집            — System CPU/MEM/DISK + App CPU%/MEM%/RSS(MB)
#   4) 프로세스 임계 경고   — envfile 의 MEMORY_LIMIT / CPU_MAX_OCCUPY 80% 도달 시 WARNING
#                            (가드 발동 *이전* 에 예고 시그널을 잡기 위함)
#   5) 로그 누적            — $AGENT_LOG_DIR/monitor.log  (시계열 한 줄 형식)
#
# 임계의 의미 (미션 5와 다름)
#   - APP_RSS_MB > MEMORY_LIMIT * 0.8  → 메모리 임계 도달 임박 (MemoryGuard 발동 직전)
#   - APP_CPU%   > CPU_MAX_OCCUPY * 0.8 → CPU 임계 도달 임박 (Watchdog 발동 직전)
#   - 시스템 전체 임계는 정보만 출력 (WARNING 으로 격하 안 함)
#
# 사용
#   1회:        ./monitor.sh
#   반복:       watch -n 2 ./monitor.sh
#   raw 캡처:   ./monitor.sh && ps -eLf | grep agent-leak-app   (별도 명령으로)

set -u   # 미정의 변수 사용 시 즉시 에러 (운영 스크립트의 안전망)

# =====================================================
# 0. 환경 변수 로드
# =====================================================
ENV_FILE="/home/agent-admin/agent-leak-app.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

: "${AGENT_HOME:?AGENT_HOME not set — envfile missing?}"
: "${AGENT_PORT:?AGENT_PORT not set}"
: "${AGENT_LOG_DIR:?AGENT_LOG_DIR not set}"
: "${MEMORY_LIMIT:?MEMORY_LIMIT not set in envfile (06 신규)}"
: "${CPU_MAX_OCCUPY:?CPU_MAX_OCCUPY not set in envfile (06 신규)}"

LOG_FILE="$AGENT_LOG_DIR/monitor.log"
PROCESS_PATTERN="agent-leak-app"

# 시스템 임계는 정보용 — WARNING 안 띄움 (06 부검 환경에선 의미 약함)
INFO_CPU=20
INFO_MEM=10
INFO_DISK=80

# 프로세스 임계 — envfile 기반, 가드 발동의 80% 지점에서 예고
THRESH_APP_RSS_MB=$(awk -v m="$MEMORY_LIMIT"   'BEGIN { printf "%d", m * 0.8 }')
THRESH_APP_CPU=$(awk    -v c="$CPU_MAX_OCCUPY" 'BEGIN { printf "%d", c * 0.8 }')

# =====================================================
# 1. 자원 수집 함수들 — TODO(human)
# =====================================================

# CPU 사용률(%) — 소수 1자리
#   top -bn1 의 "%Cpu(s)" 라인에서 idle 값을 찾아 100 에서 차감
#   awk: -F'[ ,]+' 로 콤마/공백 모두 구분자 → 필드를 순회하며 "id" 직전 값을 얻음
get_cpu_usage() {
  top -bn1 | awk -F'[ ,]+' '
    /Cpu\(s\)/ {
      for (i=1; i<=NF; i++)
        if ($i == "id") { printf "%.1f", 100 - $(i-1); exit }
    }'
}

# 메모리 사용률(%) — 소수 1자리
#   free -m 의 "Mem:" 라인에서 used($3) / total($2) * 100
get_mem_usage() {
  free -m | awk '/^Mem:/ { printf "%.1f", $3/$2*100 }'
}

# 루트 파티션(/) 사용률 — 정수(%)
#   df -P / 의 두 번째 줄 5번째 컬럼에서 % 제거
get_disk_used() {
  df -P / | awk 'NR==2 { gsub(/%/, "", $5); print $5 }'
}

# agent-leak-app 자원 사용률 — 후보 PID 들의 %cpu / %mem / RSS(MB) 합산
#   - 입력: 공백 구분 PID 문자열 (get_app_pids 결과)
#   - 출력: "<cpu> <mem> <rss_mb>" 한 줄, 각 소수 1자리
#   - 한 번의 ps 호출로 세 값 동시 측정 (race / 측정 시점 어긋남 최소화)
#   - rss 는 ps 기본 단위 KB → 1024 로 나눠 MB
#   - "$pids" 는 반드시 따옴표로 묶어 단일 인자로 전달 → procps ps 가 공백/콤마
#     구분 PID 리스트로 파싱. 따옴표 빼면 워드 스플리팅으로 ps 가 깨진다.
#   - -o %cpu=,%mem=,rss= 의 "=" 는 헤더 제거 (필드명 = 빈 헤더)
get_app_usage() {
  local pids="$1"
  ps -p "$pids" -o %cpu=,%mem=,rss= \
    | awk '{ c += $1; m += $2; r += $3 } END { printf "%.1f %.1f %.1f", c, m, r/1024 }'
}

# =====================================================
# 2. Health Check — TODO(human)
# =====================================================

# agent-leak-app 후보 PID 목록 (공백 구분 한 줄)
#   - cmdline 끝이 "/agent-leak-app" 또는 " agent-leak-app" 인 것만 매치
#     → 절대/상대 경로 양쪽 커버
#   - 함정: Rosetta(Apple Silicon → amd64) 환경에서 cmdline 이 3토큰으로 펼쳐짐
#     `<rosetta-loader> <interpreter-target> <학습자가 입력한 argv[0]>`
#     마지막 토큰이 셸 입력 그대로(예: `./agent-leak-app`)라 절대 경로 $ 앵커는 실패.
#   - 같은 패턴에 부모/자식 2개가 매치될 수 있음 (Rosetta) → "후보 전부" 반환,
#     자원 합산은 호출자(get_app_usage) 가 ps 로 처리.
get_app_pids() {
  pgrep -f '[/ ]agent-leak-app$' | xargs   # 줄바꿈 → 공백
}

# 프로세스 헬스체크 — 후보가 0개면 FAIL/exit 1, 1개 이상이면 PIDS 문자열 echo
#   06 변경: [FAIL] 시 monitor.log 에 한 줄 사망 마커 append 후 exit
#            → 시계열의 마지막 라인 = "PROCESS_DOWN @ <ts>" 로 사망 시점 명시
#            (사후 부검에서 "언제 죽었는가" 가 monitor.log 단독으로 확정됨)
check_process() {
  local pids
  pids=$(get_app_pids)
  if [[ -z "$pids" ]]; then
    echo "Checking process '${PROCESS_PATTERN}'... [FAIL]" >&2
    printf "[%s] PROCESS_DOWN pattern=%s\n" \
      "$(date '+%Y-%m-%d %H:%M:%S')" "${PROCESS_PATTERN}" >> "$LOG_FILE"
    exit 1
  fi
  echo "$pids"
}

# 포트 LISTEN 확인 (참고 — 직접 작성된 예)
check_port() {
  if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":${AGENT_PORT}\$"; then
    echo "Checking port ${AGENT_PORT}... [OK]"
    return 0
  fi
  echo "Checking port ${AGENT_PORT}... [FAIL]" >&2
  exit 1
}

# 방화벽 상태 (실패 시 WARNING만, 종료 X)
#   - ufw status는 root만 가능 → sudoers에 fine-grained 권한 부여됨
check_firewall() {
  if sudo -n ufw status 2>/dev/null | grep -q "Status: active"; then
    return 0
  fi
  echo "[WARNING] Firewall (UFW) is not active"
}

# =====================================================
# 3. 임계값 경고 — TODO(human)
# =====================================================

# 임계값 초과 시 [WARNING] 출력
#   - bash는 정수만 비교 가능 → awk 의 exit code 로 부동소수점 비교
#   - exit !(v>t): v>t 가 참(1)이면 exit 0, 거짓이면 exit 1
#   - 쉘의 `if` 가 exit code 로 분기
#   - 06 변경: unit 인자 추가 — RSS(MB) 처럼 % 가 아닌 임계도 지원
check_threshold() {
  local name=$1 value=$2 thresh=$3 unit=${4:-%}
  if awk -v v="$value" -v t="$thresh" 'BEGIN { exit !(v > t) }'; then
    echo "[WARNING] ${name} threshold exceeded (${value}${unit} > ${thresh}${unit})"
  fi
}

# =====================================================
# 4. 메인 흐름 (06: 대화형 부검 중심)
# =====================================================
main() {
  echo "====== SYSTEM MONITOR RESULT ======"
  echo
  echo "[HEALTH CHECK]"

  # 서브쉘 안의 exit 1 은 메인까지 전파되지 않으므로 || exit 1 로 명시 catch
  local pids
  pids=$(check_process) || exit 1
  echo "Checking process '${PROCESS_PATTERN}'... [OK] (PIDs: $pids)"
  check_port
  check_firewall

  echo
  echo "[RESOURCE MONITORING]"
  local sys_cpu sys_mem sys_disk app_cpu app_mem app_rss
  sys_cpu=$(get_cpu_usage)
  sys_mem=$(get_mem_usage)
  sys_disk=$(get_disk_used)
  read -r app_cpu app_mem app_rss < <(get_app_usage "$pids")

  printf "CPU   System: %5s%%   App: %5s%% / max %s%%\n"     "$sys_cpu"  "$app_cpu"  "$CPU_MAX_OCCUPY"
  printf "MEM   System: %5s%%   App: %5s%%  RSS: %sMB / limit %sMB\n" \
                                             "$sys_mem"  "$app_mem"  "$app_rss" "$MEMORY_LIMIT"
  printf "DISK  System: %5s%%\n"             "$sys_disk"

  echo
  # 프로세스 임계 (장애 가드 발동 임박 — 학습 핵심)
  check_threshold "APP_RSS" "$app_rss" "$THRESH_APP_RSS_MB" "MB"
  check_threshold "APP_CPU" "$app_cpu" "$THRESH_APP_CPU"    "%"

  # 로그 누적 — 시계열 한 줄 (장애 추적용)
  local ts pids_csv
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  pids_csv=$(echo "$pids" | tr ' ' ',')
  printf "[%s] PIDS:%s SYS_CPU:%s%% SYS_MEM:%s%% APP_CPU:%s%% APP_MEM:%s%% APP_RSS_MB:%s DISK:%s%% THREADS:%s MT:%s\n" \
    "$ts" "$pids_csv" "$sys_cpu" "$sys_mem" "$app_cpu" "$app_mem" "$app_rss" "$sys_disk" \
    "$(ps -p "$pids" -o nlwp= 2>/dev/null | awk '{s+=$1} END{print s+0}')" \
    "${MULTI_THREAD_ENABLE:-?}" >> "$LOG_FILE"

  echo
  echo "[INFO] Log appended: $LOG_FILE"
}

main "$@"
