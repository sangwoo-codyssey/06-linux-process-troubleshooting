# Mission 06 — 리눅스 프로세스 및 시스템 리소스 트러블슈팅

> `agent-leak-app` 에서 발생하는 3종 시스템 장애(OOM / CPU Spike / Deadlock) 를
> 재현·분석하고 GitHub Issue 형태의 기술 리포트로 정리한다.
>
> 미션 과제 노트 원본: [`../06-linux-process-troubleshooting.md`](../06-linux-process-troubleshooting.md)

## 시나리오 진행 상황

| # | 시나리오 | 상태 | 리포트 | Evidence |
| --- | --- | --- | --- | --- |
| 1 | **OOM** (메모리 누수 → MemoryGuard SELF-TERMINATED) | ✅ Done | [`reports/01-oom.md`](reports/01-oom.md) | [`evidence/01-oom/`](evidence/01-oom/) |
| 2 | **CPU 과점유** ([CRITICAL] CPU Threshold Violated, 50% 고정 임계) | ✅ Done | [`reports/02-cpu.md`](reports/02-cpu.md) | [`evidence/02-cpu/`](evidence/02-cpu/) |
| 3 | **Deadlock** (멀티스레드 무응답) | ⏳ TODO | — | — |
| ★ | (보너스) 스케줄링 알고리즘 추론 | ⏳ TODO | — | — |

## 디렉터리 구조

```
06-linux-process-troubleshooting/
├── README.md                      ← 이 파일 (진행 상황 + 사용법)
├── Dockerfile                     ← Ubuntu 24.04 + procps/htop/ufw/cron/...
├── run.sh                         ← docker 컨테이너 라이프사이클 (build/up/shell/...)
├── setup-mission.sh               ← agent-leak-app 부트 조건 자동 구성
├── monitor.sh                     ← 시계열 자원 부검 스크립트
├── agent-leak-app                 ← 제공 바이너리 (x86, Rosetta로 amd64 컨테이너에서 실행)
├── agent-leak-app-arm64.bak       ← arm64 백업 (호스트 직접 실행 시)
├── reports/                       ← [Bug] {장애유형} 리포트 3건
│   └── 01-oom.md
├── evidence/                      ← 각 시나리오 회차별 원본 로그 (재현 자료)
│   └── 01-oom/
│       ├── run-0-pilot/           (app.log)
│       ├── run-1-limit-64mb/      (app.log + monitor.log) ← Before
│       └── run-2-limit-256mb/     (app.log + monitor.log) ← After
└── screenshots/                   ← 필요 시 top/htop/ps 스크린샷
```

## 사용법

### 1) 컨테이너 빌드 + 기동

```bash
./run.sh build         # Ubuntu 24.04 amd64 이미지 빌드 (한 번만)
./run.sh up            # 컨테이너 백그라운드 기동 (codyssey06)
./run.sh shell         # 컨테이너에 root 셸로 접속
./run.sh status        # 컨테이너 상태
```

> ⚠️ **포트 충돌**: mission 05 컨테이너가 떠 있으면 15034 포트가 점유되어 06 기동 실패.
> `cd ../05-linux-monitor-automation && ./run.sh stop` 으로 정지 후 06 기동.

### 2) 부트 조건 구성 (한 번)

컨테이너 안에서:

```bash
docker exec codyssey06 /app/setup-mission.sh           # 부트 조건 자동 구성
docker exec codyssey06 /app/setup-mission.sh verify    # 결과 검증
```

`setup-mission.sh` 가 하는 일:
1. UFW 활성화 + 20022/15034 허용
2. `agent-admin` 사용자/그룹 (`agent-common`, `agent-core`) 생성
3. `AGENT_HOME` (`/home/agent-admin/agent-leak-app`), `upload_files`, `api_keys`, `/var/log/agent-leak-app` 디렉터리/권한
4. `secret.key` 파일 (내용: `agent_api_key_test`)
5. envfile (`/home/agent-admin/agent-leak-app.env`) + `.profile` source
6. 호스트의 `agent-leak-app` 바이너리를 `AGENT_HOME` 으로 install

### 3) 시나리오 실행 사이클

```bash
# (a) envfile 의 시나리오 변수 수정 — vim 등으로 직접
docker exec -it codyssey06 vim /home/agent-admin/agent-leak-app.env

# (b) 로그 초기화
docker exec codyssey06 bash -c ': > /var/log/agent-leak-app/{app,monitor}.log'

# (c) monitor.sh 백그라운드 시계열 (재현 시간보다 약간 길게)
docker exec -d codyssey06 bash -c 'for i in $(seq 1 60); do /app/monitor.sh > /dev/null 2>&1; sleep 1; done'

# (d) agent-leak-app 부팅 (agent-admin, .profile 통해 envfile 자동 source)
docker exec -d --user agent-admin -w /home/agent-admin/agent-leak-app codyssey06 \
  bash -lc 'exec ./agent-leak-app > /var/log/agent-leak-app/app.log 2>&1 < /dev/null'

# (e) 종료 후 캡처
docker exec codyssey06 cat /var/log/agent-leak-app/app.log     > evidence/0X-.../app.log
docker exec codyssey06 cat /var/log/agent-leak-app/monitor.log > evidence/0X-.../monitor.log
```

## 환경 변수 — 시나리오 제어

envfile (`/home/agent-admin/agent-leak-app.env`) 의 다음 3개 값으로 *어떤 장애를 단독 관측할지* 가 결정된다.

| 시나리오 | `MEMORY_LIMIT` (MB) | `CPU_MAX_OCCUPY` (%) | `MULTI_THREAD_ENABLE` |
| --- | ---: | ---: | --- |
| **OOM** (메모리 단독) | **64** (작게) | 20 (안전 영역) | false |
| **CPU** (CPU 단독) | 512 (여유) | **80** (위험 영역, 50% 초과) | false |
| **Deadlock** (스레드 락) | 512 (여유) | 20 (안전 영역) | **true** |

> ⚠️ **CPU_MAX_OCCUPY 의미는 OOM 의 MEMORY_LIMIT 과 *방향이 거꾸로*** — 실험으로 확인:
>
> - 시스템 실제 CPU 임계는 *고정 50%* (부팅 메시지 `Recommend Under 50%` 의 진짜 의미)
> - `CPU_MAX_OCCUPY` 는 CpuWorker 의 *ramp-up 목표* 일 뿐, *그 값 자체가 임계는 아님*
> - 50% 미만 → CpuWorker self-cooldown 으로 영원 안전
> - 50% 이상 → ramp 도중 임계 통과 시 `[CRITICAL] CPU Threshold Violated` 로 종료
>
> 자세한 분석: [`reports/02-cpu.md`](reports/02-cpu.md) §3
>
> 원칙: *관심 있는 가드만 빡빡하게, 나머지는 영향 최소화* — 두 가드가 동시에 발동하면 *어느 가드가 먼저 죽였는지* 가 모호해진다.

### 부트 시퀀스가 요구하는 인프라 변수 (거의 안 바꿈)

| 변수 | 값 |
| --- | --- |
| `AGENT_HOME` | `/home/agent-admin/agent-leak-app` |
| `AGENT_PORT` | `15034` |
| `AGENT_UPLOAD_DIR` | `$AGENT_HOME/upload_files` |
| `AGENT_KEY_PATH` | `$AGENT_HOME/api_keys` |
| `AGENT_LOG_DIR` | `/var/log/agent-leak-app` |

## monitor.sh — 미션 5 → 6 변경 요지

| 측면 | 미션 5 | 미션 6 |
| --- | --- | --- |
| 호출 컨텍스트 | cron 매분 자동 | 학습자 대화형 또는 `watch -n 2` |
| 임계 기준 | 시스템 전체 (CPU>20%, MEM>10%) | 프로세스 자체 (`MEMORY_LIMIT`/`CPU_MAX_OCCUPY` × 0.8) |
| 신규 측정 | — | `APP_RSS_MB` (절대 MB), `THREADS` (nlwp), `MT` (mode) |
| 사망 마커 | 없음 (사망 시점 모호) | `PROCESS_DOWN @ <ts>` 한 줄로 명시 |

## 학습 노트 — 함정과 발견

### 1) Rosetta 의 cmdline 트릭

Apple Silicon 호스트에서 amd64 컨테이너의 x86 바이너리를 실행하면 `ps` 의 cmdline 이 *3토큰* 으로 펼쳐진다:

```
/run/rosetta/rosetta  /home/agent-admin/agent-leak-app/agent-leak-app  ./agent-leak-app
```

마지막 토큰이 *셸 입력 그대로* (`./agent-leak-app`) 라 `pgrep -f '/home/.../agent-leak-app$'` 같은 절대경로 + `$` 앵커 패턴은 매치 실패. 해결: `pgrep -f '[/ ]agent-leak-app$'`.

### 2) `./run.sh exec` 의 `-it` 함정

비대화형 자동화 (CI, Bash tool 등) 에서 `docker exec -it ...` 는 TTY 를 못 잡고 stdin 이 닫히면서 *실제 원인과 무관한 에러 메시지* (예: `mkdir: /app: Read-only file system`) 가 흘러나옴. 자동화에선 `docker exec` 를 *직접* 호출하거나 `./run.sh exec` 분기를 비대화형용으로 분리해야 함.

### 3) monitor.sh 가 `PROCESS_DOWN` 마커를 남기는 이유

[FAIL] 시 monitor.log 에 한 줄도 안 남기면, *언제 죽었는지* 가 시계열의 마지막 정상 라인 뒤로 사라진다. `PROCESS_DOWN @ <ts>` 한 줄을 남기면 시계열이 끊기지 않고 ① 정상 라인 → ② PROCESS_DOWN 으로 *사망 시점이 한 라인에 명시* 된다. 운영의 로그 이중화 가치를 실험적으로 검증.

### 4) 시나리오 실행 순서: monitor 먼저, app 나중

`docker exec -d` 의 bash login 셸 초기화에 ~2초 지연이 있어, agent 를 먼저 띄우면 monitor 가 *부팅 전 시점* 에 호출되어 [FAIL]. *monitor 백그라운드 루프를 먼저* 시작하고 1초 후 agent 부팅하면 시계열이 깨끗하게 잡힌다.

---

## 결과물 제출 형태

- 시나리오 3건 모두 완료 후 GitHub 레포 `06-linux-process-troubleshooting` 생성
- 각 `reports/0X-*.md` 를 GitHub Issue 로 등록 (미션 5 패턴: `sangwoo-codyssey/0X-...`)
- Issue 링크를 본 README 의 *시나리오 진행 상황* 표에 추가
