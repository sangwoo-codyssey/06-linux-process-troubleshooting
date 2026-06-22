# Mission 06 — 리눅스 프로세스 및 시스템 리소스 트러블슈팅

> `agent-leak-app` 의 3종 시스템 장애(OOM / CPU Spike / Deadlock) 부검 + 스케줄링 알고리즘 추론 (보너스).
>
> 미션 노트 원본: [`../06-linux-process-troubleshooting.md`](../06-linux-process-troubleshooting.md)

## 시나리오 · 산출물

| # | 시나리오 | 리포트 | Evidence | GitHub Issue |
| --- | --- | --- | --- | --- |
| 1 | OOM (Memory Leak → MemoryGuard) | [`reports/01-oom.md`](reports/01-oom.md) | [`evidence/01-oom/`](evidence/01-oom/) | [#1](https://github.com/sangwoo-codyssey/06-linux-process-troubleshooting/issues/1) |
| 2 | CPU 과점유 (Watchdog) | [`reports/02-cpu.md`](reports/02-cpu.md) | [`evidence/02-cpu/`](evidence/02-cpu/) | [#2](https://github.com/sangwoo-codyssey/06-linux-process-troubleshooting/issues/2) |
| 3 | Deadlock (멀티스레드 무응답) | [`reports/03-deadlock.md`](reports/03-deadlock.md) | [`evidence/03-deadlock/`](evidence/03-deadlock/) | [#3](https://github.com/sangwoo-codyssey/06-linux-process-troubleshooting/issues/3) |
| ★ | (보너스) 스케줄링 알고리즘 추론 | [`reports/04-scheduling.md`](reports/04-scheduling.md) | [`evidence/04-scheduling/`](evidence/04-scheduling/) | [#4](https://github.com/sangwoo-codyssey/06-linux-process-troubleshooting/issues/4) |

학습자 본인 노트 · 실험 인프라 사용법 · 함정 기록: [`LEARNING-NOTES.md`](LEARNING-NOTES.md)
