#!/bin/bash
# 미션 6: agent-leak-app 부트 조건 사전 구성 스크립트
#
# 목적
#   - 미션 6 4.1 "사전 준비 사항" 표에 정의된 11개 조건을 컨테이너 안에서 한 번에 만족시킨다.
#   - 06은 "장애 부검"이 본질이므로, 부트 자체를 학습 포인트로 삼지 않는다.
#     → 미션 5 setup 의 자연 발견 거리(setgid/traverse/sudoers 등)는 의도적으로 제거.
#   - idempotent: 중복 실행해도 안전.
#
# 미션 5 → 6 차이점 (중요)
#   - AGENT_KEY_PATH 가 *파일* → *디렉터리* 로 의미 변경
#   - 키 파일명: t_secret.key → secret.key
#   - 신규 환경변수 3종 추가: MEMORY_LIMIT, CPU_MAX_OCCUPY, MULTI_THREAD_ENABLE
#
# 사용
#   컨테이너 안에서:  ./run.sh exec /app/setup-mission.sh
#   검증 모드 추가:    ./run.sh exec /app/setup-mission.sh verify

set -e

echo "=========================================="
echo "  미션 6: agent-leak-app 부트 조건 구성"
echo "=========================================="

# -------------------------------------------
# 1단계: 네트워크 — 포트 15034 바인딩 가능 보장
#   - UFW 를 활성화하고 15034/tcp 만 허용
#   - SSH 학습은 미션 5에서 끝났으므로 20022 는 컨테이너 외부 접근용으로만 열어둠
# -------------------------------------------
echo ""
echo "[1단계] UFW + 포트 정책"

ufw --force reset >/dev/null
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 20022/tcp        >/dev/null
ufw allow 15034/tcp        >/dev/null
ufw --force enable         >/dev/null
echo "  - UFW 활성화 + 20022/15034 허용"

# -------------------------------------------
# 2단계: 계정/그룹
#   - 미션 노트: "root 가 아닌 일반 사용자"
#   - 미션 5 의 사용자 체계를 그대로 계승해도 무방하나, 06 만으로 닫힌 형태를 위해
#     agent-admin 만 만들어도 충분
# -------------------------------------------
echo ""
echo "[2단계] 일반 사용자 (agent-admin)"

getent group agent-common >/dev/null || groupadd agent-common
getent group agent-core   >/dev/null || groupadd agent-core
id agent-admin &>/dev/null || useradd -m -s /bin/bash -G agent-common,agent-core agent-admin
usermod -G agent-common,agent-core agent-admin
echo "  - agent-admin 준비 완료 (보조 그룹: agent-common, agent-core)"

# -------------------------------------------
# 3단계: 디렉터리 — AGENT_HOME / upload_files / api_keys / AGENT_LOG_DIR
#   - 모두 agent-admin 이 쓸 수 있어야 함 (앱이 일반 사용자로 실행되므로)
# -------------------------------------------
echo ""
echo "[3단계] 디렉터리/권한"

AGENT_HOME="/home/agent-admin/agent-leak-app"
mkdir -p "$AGENT_HOME/upload_files"
mkdir -p "$AGENT_HOME/api_keys"
mkdir -p /var/log/agent-leak-app

chown -R agent-admin:agent-common "$AGENT_HOME"
chmod 750 "$AGENT_HOME"
chmod 770 "$AGENT_HOME/upload_files"
chown agent-admin:agent-core "$AGENT_HOME/api_keys"
chmod 770 "$AGENT_HOME/api_keys"
chown agent-admin:agent-core /var/log/agent-leak-app
chmod 770 /var/log/agent-leak-app

echo "  - $AGENT_HOME (agent-admin:agent-common, 750)"
echo "  - $AGENT_HOME/upload_files (770)"
echo "  - $AGENT_HOME/api_keys (agent-admin:agent-core, 770)"
echo "  - /var/log/agent-leak-app (agent-admin:agent-core, 770)"

# -------------------------------------------
# 4단계: secret.key
#   - 경로: $AGENT_HOME/api_keys/secret.key
#   - 내용: agent_api_key_test  (미션 노트 고정값)
# -------------------------------------------
echo ""
echo "[4단계] secret.key"

KEY_FILE="$AGENT_HOME/api_keys/secret.key"
echo 'agent_api_key_test' > "$KEY_FILE"
chown agent-admin:agent-core "$KEY_FILE"
chmod 640 "$KEY_FILE"
echo "  - $KEY_FILE (agent-admin:agent-core, 640)"

# -------------------------------------------
# 5단계: envfile + .profile source
#   - 미션 5 의 SSOT 패턴 그대로 계승
#   - 06 신규 변수 3종 추가
#
#   ※ MEMORY_LIMIT / CPU_MAX_OCCUPY / MULTI_THREAD_ENABLE 의 *초기 기본값* 은
#     TODO(human) — 학습자가 시나리오 의도에 맞게 직접 채워 본다.
#     (선택의 의미는 setup 실행 후 인사이트로 해설)
# -------------------------------------------
echo ""
echo "[5단계] envfile + .profile source"

ENV_FILE="/home/agent-admin/agent-leak-app.env"
cat > "$ENV_FILE" <<'EOF'
# Codyssey mission 6 - agent-leak-app 환경 변수
# (수정 시 이 파일만 고치면 .profile/monitor.sh 모두 반영됨)

# =====================================================
# [A] 시나리오 제어 — 매 실행 직전 학습자가 조정하는 값
# =====================================================
# 범위:
#   MEMORY_LIMIT        : 50 ~ 512  (MB)
#   CPU_MAX_OCCUPY      : 10 ~ 100  (%)
#   MULTI_THREAD_ENABLE : true / false
#
# 시나리오별 권장값 (한 시나리오만 깔끔히 단독 관측하기 위한 조합)
#   ┌──────────┬───────────────┬───────────────┬──────────────────────┐
#   │ 시나리오 │ MEMORY_LIMIT  │ CPU_MAX_OCCUPY│ MULTI_THREAD_ENABLE  │
#   ├──────────┼───────────────┼───────────────┼──────────────────────┤
#   │ OOM      │ 64 (작게)     │ 20 (안전)     │ false                │
#   │ CPU      │ 512 (여유)    │ 80 (위험)     │ false                │
#   │ Deadlock │ 512 (여유)    │ 20 (안전)     │ true                 │
#   └──────────┴───────────────┴───────────────┴──────────────────────┘
#
# ※ CPU_MAX_OCCUPY 의 *의미가 OOM과 다름*에 주의 (실험으로 확인된 사실):
#   - 시스템 실제 임계는 *고정 50%* (부팅 메시지 "Recommend Under 50%" 의 진짜 의미)
#   - CPU_MAX_OCCUPY 는 CpuWorker 의 *ramp-up 목표*. 50% 미만이면 self-cooldown 으로 영원 안전,
#     50% 이상이면 ramp 도중 임계 통과 → [CRITICAL] CPU Threshold Violated 종료.
#   → OOM 시나리오에선 CPU 변수가 80(위험)일 필요 없으므로 20(안전) 으로 두어 가드 충돌 최소화.
#     CPU 시나리오에서만 80 으로 올려 Watchdog 발동 관측.
#
# 현재 시나리오: OOM (첫 시나리오)
#   - MEMORY_LIMIT 을 작게 잡아 임계 도달을 빠르게
#   - CPU_MAX_OCCUPY/MULTI_THREAD_ENABLE 은 영향 최소화하여 OOM 신호 단독 관측
# TODO(human): 시나리오 전환 시 위 표를 참고하여 직접 수정.
export MEMORY_LIMIT=64
export CPU_MAX_OCCUPY=95
export MULTI_THREAD_ENABLE=false

# =====================================================
# [B] 부트 시퀀스 필수 — 인프라 고정값 (거의 안 바꿈)
# =====================================================
export AGENT_HOME=/home/agent-admin/agent-leak-app
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR=$AGENT_HOME/upload_files
export AGENT_KEY_PATH=$AGENT_HOME/api_keys
export AGENT_LOG_DIR=/var/log/agent-leak-app
EOF
chown agent-admin:agent-core "$ENV_FILE"
chmod 640 "$ENV_FILE"
echo "  - $ENV_FILE 생성 (TODO(human) 3개 자리 남김)"

# .profile 에서 envfile source — 중복 방지
PROFILE=/home/agent-admin/.profile
if ! grep -qF 'agent-leak-app.env' "$PROFILE" 2>/dev/null; then
  cat >> "$PROFILE" <<'EOF'

# Codyssey mission 6 - envfile auto load
[ -f /home/agent-admin/agent-leak-app.env ] && source /home/agent-admin/agent-leak-app.env
EOF
  chown agent-admin:agent-admin "$PROFILE"
  echo "  - .profile 에 source 라인 추가"
else
  echo "  - .profile 이미 source 라인 보유 (skip)"
fi

# -------------------------------------------
# 6단계: 바이너리 배치 (있을 때만)
#   - 호스트 디렉터리(/app)에 agent-leak-app 이 들어와 있으면 AGENT_HOME 으로 복사
#   - 없으면 안내만 출력하고 통과 (사용자가 수동 배치 시점에 맞춰 재실행)
# -------------------------------------------
echo ""
echo "[6단계] 바이너리 배치"

BIN_SRC="/app/agent-leak-app"
BIN_DST="$AGENT_HOME/agent-leak-app"
if [[ -f "$BIN_SRC" ]]; then
  install -o agent-admin -g agent-core -m 0750 "$BIN_SRC" "$BIN_DST"
  echo "  - $BIN_SRC → $BIN_DST (agent-admin:agent-core, 0750)"
else
  echo "  ! $BIN_SRC 없음 — 바이너리 수령 후 호스트 디렉터리에 두고 본 스크립트를 재실행하세요."
fi

echo ""
echo "=========================================="
echo "  완료! 다음 단계:"
echo "    1) /home/agent-admin/agent-leak-app.env 에서 TODO(human) 3개 값 채우기"
echo "    2) su - agent-admin"
echo "    3) cd \$AGENT_HOME && ./agent-leak-app"
echo "  검증 모드: ./setup-mission.sh verify"
echo "=========================================="

# -------------------------------------------
# 검증 모드
# -------------------------------------------
if [[ "${1:-}" == "verify" ]]; then
  echo ""
  echo "==== 검증 ===="
  echo "[id]";       id agent-admin
  echo "[group]";    getent group agent-common; getent group agent-core
  echo "[dirs]";     ls -la "$AGENT_HOME"; ls -la /var/log/agent-leak-app
  echo "[key]";      ls -la "$AGENT_HOME/api_keys/secret.key" && echo "내용: $(cat $AGENT_HOME/api_keys/secret.key)"
  echo "[env]";      cat "$ENV_FILE" | grep -E '^export' || true
  echo "[ufw]";      ufw status verbose || true
  echo "[bin]";      ls -la "$AGENT_HOME/agent-leak-app" 2>/dev/null || echo "  ! 바이너리 미배치"
fi
