#!/bin/bash
set -e

IMAGE_NAME="codyssey06-linux"
CONTAINER_NAME="codyssey06"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 바인드 마운트 경로: 환경변수 > 두 번째 인자 > 기본값(스크립트 위치)
APP_DIR="${APP_DIR:-${2:-$SCRIPT_DIR}}"
APP_DIR="$(eval echo "$APP_DIR")"
mkdir -p "$APP_DIR"

# UFW/iptables를 다루려면 NET_ADMIN capability가 필요하다.
# (privileged 까지는 필요 없음 — 권한 학습이 목적이므로 최소 권한 원칙 유지)
DOCKER_CAPS=(--cap-add=NET_ADMIN --cap-add=NET_RAW)
PLATFORM_FLAG="--platform=linux/amd64"

case "${1:-shell}" in
  build)
    echo "=== Docker 이미지 빌드 (linux/amd64) ==="
    docker build $PLATFORM_FLAG -t "$IMAGE_NAME" "$SCRIPT_DIR"
    echo "빌드 완료: $IMAGE_NAME"
    ;;
  up)
    # 장시간 운영 환경처럼 사용하기 위해 컨테이너를 백그라운드로 띄워 둔다.
    # 안에서 설정한 SSH/UFW/계정 등이 컨테이너 수명 동안 유지된다.
    if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
      echo "=== 이미지가 없어 자동 빌드합니다 ==="
      docker build $PLATFORM_FLAG -t "$IMAGE_NAME" "$SCRIPT_DIR"
    fi
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    echo "=== 컨테이너 기동 (백그라운드, --init 적용) ==="
    # --init: Docker가 tini 를 PID 1 로 끼워넣음 → 좀비(defunct) 자동 reaping
    #         agent-leak-app/sudo 등이 종료되어 고아가 되어도 tini가 wait()해줘서 PID 슬롯 회수됨
    docker run -d --init \
      $PLATFORM_FLAG \
      "${DOCKER_CAPS[@]}" \
      --name "$CONTAINER_NAME" \
      --hostname "codyssey06" \
      -p 20022:20022 \
      -p 15034:15034 \
      -v "$APP_DIR:/app" \
      "$IMAGE_NAME" \
      tail -f /dev/null
    echo "컨테이너 실행 중: $CONTAINER_NAME"
    echo "접속: ./run.sh shell"
    ;;
  shell)
    # 이미 떠 있는 컨테이너에 접속한다. 없으면 띄운다.
    if ! docker ps -q -f name="^${CONTAINER_NAME}$" | grep -q .; then
      echo "=== 컨테이너가 없어 자동 기동합니다 ==="
      "$0" up
    fi
    docker exec -it "$CONTAINER_NAME" /bin/bash
    ;;
  exec)
    # 임의 명령 실행: ./run.sh exec id agent-admin
    shift
    docker exec -it "$CONTAINER_NAME" "$@"
    ;;
  stop)
    # 컨테이너 정지 (파일시스템 상태는 유지 — 사용자/그룹/sshd_config/UFW config 등)
    # 단, 실행 중이던 데몬과 커널 상태(iptables 적재)는 사라지므로 start 시 재기동 필요.
    echo "=== 컨테이너 정지 (상태 유지) ==="
    docker stop "$CONTAINER_NAME"
    echo "다시 켜기: ./run.sh start"
    ;;
  start)
    # 정지된 컨테이너 재시작 + 데몬 자동 복구
    if ! docker ps -a -q -f name="^${CONTAINER_NAME}$" | grep -q .; then
      echo "컨테이너가 존재하지 않습니다. ./run.sh up 으로 새로 만드세요."
      exit 1
    fi
    echo "=== 컨테이너 재시작 ==="
    docker start "$CONTAINER_NAME" >/dev/null

    # 데몬 자동 복구 — stop 으로 잃은 sshd / ufw 활성 상태를 되돌림
    echo "=== 데몬 복구 (sshd / ufw) ==="
    docker exec "$CONTAINER_NAME" bash -c '
      # sshd: sshd_config는 유지되어 있으므로 그대로 start
      service ssh start >/dev/null 2>&1 && echo "  - sshd: started" || echo "  ! sshd start failed"
      # ufw: 규칙 파일은 유지되어 있으므로 enable 시 자동 로드
      ufw --force enable >/dev/null 2>&1 && echo "  - ufw : active" || echo "  ! ufw enable failed"
    '
    echo "접속: ./run.sh shell"
    ;;
  restart)
    "$0" stop
    "$0" start
    ;;
  down)
    # 안전한 정지 — 컨테이너만 멈추고 파일시스템 상태는 보존.
    # 실수로 학습 산출물(계정/디렉터리/sshd_config 등)을 날리는 사고를 막기 위해
    # 삭제는 별도 명령(destroy)으로 분리한다.
    echo "=== 컨테이너 정지 (상태 유지 — destroy 와 다름) ==="
    docker stop "$CONTAINER_NAME"
    echo "다시 켜기: ./run.sh start"
    echo "완전 삭제: ./run.sh destroy"
    ;;
  destroy)
    # 명시적 삭제 — 컨테이너 + 파일시스템 상태 모두 소실.
    # 의도된 초기화 (학습 환경 재시작) 시에만 사용.
    echo "=== 컨테이너 정지 + 삭제 (모든 상태 소실) ==="
    read -r -p "정말 삭제하시겠습니까? (yes 입력) " confirm
    if [[ "$confirm" == "yes" ]]; then
      docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
      echo "삭제 완료."
    else
      echo "취소되었습니다."
    fi
    ;;
  logs)
    docker logs -f "$CONTAINER_NAME"
    ;;
  status)
    docker ps -a -f name="^${CONTAINER_NAME}$"
    ;;
  *)
    cat <<EOF
사용법: $0 {build|up|stop|start|restart|shell|exec|down|destroy|logs|status} [APP_DIR]

생명주기:
  build   - Docker 이미지 빌드
  up      - 컨테이너 백그라운드 신규 생성 (--init 포함, 좀비 방지)
  stop    - 컨테이너 정지 (파일시스템 상태 유지 — 사용자/그룹/설정 보존)
  start   - 정지된 컨테이너 재시작 + sshd/ufw 자동 복구
  restart - stop + start
  down    - 컨테이너 정지만 (stop 과 동일, 상태 유지) — 실수 방지
  destroy - 컨테이너 정지 + 삭제 (모든 상태 소실, 명시 확인 필요)

조작:
  shell   - 실행 중인 컨테이너에 root 셸로 접속 (기본값)
  exec    - 컨테이너 안에서 임의 명령 실행 (예: ./run.sh exec id agent-admin)
  logs    - 컨테이너 로그 tail
  status  - 컨테이너 상태 확인

특징:
  - linux/amd64 강제 (agent-leak-app이 x86-64 ELF 바이너리)
  - NET_ADMIN capability 부여 (UFW 동작에 필요)
  - --init 사용 (좀비 reaping)
  - 호스트 포트 20022(SSH), 15034(APP) 매핑
  - 현재 디렉터리를 컨테이너의 /app 에 바인드 마운트

상태 보존 가이드:
  - 일시 정지 후 재개: stop (또는 down) → start
  - 영구 삭제 후 새로 시작: destroy → up → setup-mission.sh
EOF
    exit 1
    ;;
esac
