# [Bug] OOM — 경계값(MEMORY_LIMIT=256MB) 환경에서 메모리 누수 누적으로 MemoryGuard 자가 종료

## 1. Description (현상 설명)

### 한 줄 요약

경계값(`MEMORY_LIMIT=256MB`) 환경에서는 앱 가동시간만큼 메모리 누수가 누적되어, MemoryGuard 정책에 의한 OOM 종료가 발생한다.

### 발생 조건

envfile (`MEMORY_LIMIT=256` / `CPU_MAX_OCCUPY=20` / `MULTI_THREAD_ENABLE=false`) 로 `./agent-leak-app` 실행 시, 시간이 지날수록 메모리 사용량이 선형 증가하여 약 35초 시점에 `[CRITICAL] [MemoryGuard] Memory limit exceeded (275MB >= 256MB)` 로 OOM 종료된다.

부팅 메시지에 `[ MEMORY ] Limit: 256MB [ WARNING: Recommend Over 256MB ]` 가 출력되어, 256MB 가 권장값 이상이 아니라 경계값임이 명시된다.

## 2. Evidence & Logs (증거 자료)

### 2.1 Before / After 요약

| 지표 | Before (256MB) | After (512MB) |
| --- | ---: | ---: |
| 부팅 시나리오 | OOM (Recommend Over 256MB WARNING) | Healthy System Monitoring (OK) |
| 생존시간 | 35초 | 140초+ 미종료 |
| 임계 동작 | MemoryGuard `Self-terminating` (프로세스 종료) | MemoryWorker `Memory Cache Flushed` (사이클 반복) |
| 임계 발동 Heap | 275MB | 525MB |
| APP_RSS_MB 최대 | 283.6 | 533.8 |
| SYS_MEM 시작 / 최대 | 48.9% / 52.1% | 49.0% / 55.6% |
| SYS_MEM Δ | +3.2%pt | +6.6%pt (사이클당) |
| 종료 후 PID | 사라짐 | 유지, 누적 사이클 반복 |

### 2.2 핵심 로그 라인

```
(Before, MEMORY_LIMIT=256MB)
[CRITICAL] [MemoryGuard] Memory limit exceeded (275MB >= 256MB) / (Recommend Over 256MB)
[CRITICAL] [MemoryGuard] Self-terminating process 16068 to prevent system instability.
```

```
(After, MEMORY_LIMIT=512MB)
[WARNING] [MemoryWorker] Memory Usage Reached Limit (525MB). Starting cleanup...
[System] Memory Cache Flushed. Process Stabilized.
>>> [SYSTEM] MEMORY RECOVERED (Cache Cleared) <<<
```

### 2.3 시계열 — Before 회차 (MEMORY_LIMIT=256MB)

`app.log` 와 `monitor.log` 를 시간순으로 병합.

| 시각 | app.log | APP_RSS_MB | APP_MEM% | SYS_MEM% |
| :--- | :--- | ---: | ---: | ---: |
| 18:17:25 | Boot Sequence start | — | — | — |
| 18:17:26 | Agent READY, listening :15034 | — | — | — |
| 18:17:27 | — | 33.6 | 0.3 | 48.9 |
| 18:17:28 | Heap: 25MB | — | — | — |
| 18:17:29 | — | 58.6 | 0.6 | 49.2 |
| 18:17:31 | Heap: 50MB | 83.6 | 0.9 | 49.5 |
| 18:17:33 | — | 83.6 | 0.9 | 49.7 |
| 18:17:34 | Heap: 75MB | — | — | — |
| 18:17:35 | — | 108.6 | 1.3 | 50.2 |
| 18:17:37 | Heap: 100MB | 108.6 | 1.3 | 49.7 |
| 18:17:38 | — | 133.6 | 1.6 | 50.3 |
| 18:17:40 | Heap: 125MB | 158.6 | 1.9 | 50.6 |
| 18:17:42 | — | 158.6 | 1.9 | 50.2 |
| 18:17:43 | Heap: 150MB | — | — | — |
| 18:17:44 | — | 183.6 | 2.2 | 50.7 |
| 18:17:46 | Heap: 175MB | 208.6 | 2.5 | 50.4 |
| 18:17:48 | — | 208.6 | 2.5 | 51.1 |
| 18:17:49 | Heap: 200MB | 233.6 | 2.8 | 51.5 |
| 18:17:51 | — | 233.6 | 2.8 | 51.4 |
| 18:17:52 | Heap: 225MB | — | — | — |
| 18:17:53 | — | 258.6 | 3.1 | 51.7 |
| 18:17:55 | Heap: 250MB | 283.6 | 3.5 | 52.1 |
| 18:17:57 | — | 283.6 | 3.5 | 52.0 |
| 18:17:58 | Heap: 275MB + [CRITICAL] 275>=256 + Self-terminating PID 16068 | — | — | — |

### 2.4 시계열 — After 회차 (MEMORY_LIMIT=512MB, 사이클 발췌)

Healthy 시나리오에서는 사이클이 반복되므로 첫 번째 사이클 + cleanup 전후만 발췌.

| 시각 | app.log | APP_RSS_MB | APP_MEM% | SYS_MEM% |
| :--- | :--- | ---: | ---: | ---: |
| 19:10:30 | Boot, Scenario: Healthy System Monitoring | — | — | — |
| 19:10:32 | Heap: 25MB | 33.6 | 0.3 | 49.0 |
| 19:11:00 | Heap: 250MB | 258.8 | 3.1 | 51.9 |
| 19:11:30 | Heap: 500MB | 508.8 | 6.3 | 55.2 |
| 19:11:33 | Heap: 525MB + [WARNING] cleanup + Cache Flushed | — | — | — |
| 19:11:34 | (사이클 직후) | 33.7 | 0.3 | 49.4 |
| 19:11:38 | Heap: 25MB (두 번째 사이클 시작) | — | — | — |
| 19:12:39 | Heap: 525MB + 두 번째 cleanup + Cache Flushed | — | — | — |

사이클 전후 PID (17652, 17660) 는 동일하게 유지된다. `monitor.log` 에서 직접 확인 가능.

### 2.5 시계열 기울기 (Before 회차 기준)

| 지표 | step / 기울기 | 비고 |
| --- | --- | --- |
| `app.log` Heap | +25MB / 3초 (8.33 MB/s) | 등차, noise 없음 |
| `monitor` APP_RSS_MB | +25MB / 약 3초 | Heap 과 동일 기울기, RSS − Heap = +33.6MB 일정 |
| `monitor` SYS_MEM% | +0.107 %pt/s | noise ±0.5%pt, 우상향 |

## 3. Root Cause Analysis (원인 분석)

### 3.1 데이터 정합

- Heap (앱 자가측정) 은 +25MB / 3초 의 등차 수열로 증가한다.
- APP_RSS_MB (OS 가 본 RSS) 는 동일한 기울기로 같이 상승하고, RSS − Heap = +33.6MB 의 일정한 오프셋만 유지된다.
- 두 시계열이 같이 올라간다는 것은, 앱이 Heap 에 쌓아두는 데이터가 실제 OS 메모리를 점유하고 있다는 의미다 (Heap 만 부풀고 RSS 가 따라오지 않는 가짜 누수와 구분된다).
- SYS_MEM 의 절대값(≈ 50%) 은 컨테이너 호스트의 기존 정적 부하이고, 시계열의 noise (±0.5%pt) 는 일시적 변동이다.

### 3.2 원인 분석 (메모리 누수)

agent-leak-app 은 가동 중 데이터를 Heap 에 지속적으로 누적하고 해제하지 않아, 시간에 비례하여 메모리 사용량이 선형 증가하는 메모리 누수 결함을 가진다. Heap 의 누적이 OS 의 RSS 와 동일한 기울기로 함께 상승하기 때문에, Heap 자가측정만 부풀어 보이는 가짜 누수가 아니라 실제로 OS 메모리를 점유하는 누수로 판단된다.

### 3.3 시스템 동작 (MEMORY_LIMIT 에 따른 분기)

envfile 의 `MEMORY_LIMIT` 값에 따라 임계 도달 시 처리 방식이 달라진다.

**(Before) MEMORY_LIMIT=256MB — 경계값 이하**

- 부팅 시 `[WARNING] Recommend Over 256MB` 출력
- OOM 시나리오로 진입
- 누수 누적이 임계 초과 시 MemoryGuard 가 `Self-terminating` 으로 프로세스를 종료
- PID 가 사라지며, 부팅 메시지 재출현 없이 단순 종료

**(After) MEMORY_LIMIT=512MB — 권장값 이상**

- 부팅 시 `[ MEMORY ] Limit: 512MB [ OK ]` 출력
- Healthy System Monitoring 시나리오로 진입
- 누수 누적이 525MB 도달 시 MemoryWorker 가 `Memory Cache Flushed` 로 자체 회수
- 같은 PID 가 유지되며, Heap 이 25MB 부터 다시 시작하는 누적 사이클이 반복

이는 OS-level OOM Killer (커널이 호스트 메모리 부족 시 외부에서 SIGKILL) 와 달리, 애플리케이션 자체가 임계를 인식하여 자율적으로 종료 또는 회수하는 내부 보호 메커니즘이다.

## 4. Workaround & Verification (조치 및 검증)

### 4.1 조치

envfile `/home/agent-admin/agent-leak-app.env` 의 `MEMORY_LIMIT` 값을 256MB → 512MB 로 상향.

### 4.2 검증 (Before / After)

| 항목 | Before (256MB) | After (512MB) | 변화 |
| --- | --- | --- | --- |
| 생존시간 | 35초 | 140초+ 미종료 | 종료 → 생존 |
| 임계 동작 | Self-terminating (PID 사라짐) | Cache Flush (PID 유지) | 종료 → 자체 회수 |
| 임계 도달 Heap | 275MB | 525MB | +250MB |
| 시나리오 | OOM | Healthy System Monitoring | 분기 변경 |

### 4.3 근본 해결 제안

실제 운영 관점에서는 단계적 접근이 적절하다.

1. **우회 조치 (즉시)** — `MEMORY_LIMIT` 을 권장값 이상 (≥ 512MB) 으로 상향하여 Healthy System Monitoring 시나리오로 진입시키고, MemoryWorker 의 Cache Flush 사이클로 프로세스 생존을 확보한다. 본 리포트 §4.1 의 조치가 이에 해당한다.

2. **정공법 (근본)** — 소스 코드 레벨에서 Heap 에 누적되는 데이터의 생성·해제 경로를 추적하고, 불필요한 객체를 주기적으로 해제하는 리팩토링을 적용한다. 누수가 제거되면 `MEMORY_LIMIT` 값에 관계없이 메모리 사용량이 일정 범위에 수렴해야 한다.

우회 조치는 시스템 안정을 즉시 확보할 수 있지만 누수 자체가 사라진 것은 아니므로, 운영 환경에서는 누수율 모니터링과 함께 정공법 작업의 우선순위를 별도로 관리해야 한다.
