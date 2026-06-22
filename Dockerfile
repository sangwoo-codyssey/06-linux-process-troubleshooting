# 미션 6: 리눅스 프로세스/시스템 리소스 트러블슈팅 학습 환경
# - Ubuntu 24.04 LTS (amd64 강제: 제공된 agent-leak-app이 x86-64 ELF 바이너리)
#   * 22.04(GLIBC 2.35)에선 agent-leak-app(GLIBC 2.38 요구 가정) 실행 불가 → 24.04(GLIBC 2.39)
# - 미션 5의 베이스 이미지를 그대로 계승하되, 06은 "장애 부검" 시나리오 중심
#   * 동일 패키지 셋 유지 → 같은 컨테이너 안에서 monitor.sh / ps / top / htop / pstree 활용
#   * htop 추가: top 보다 가시성 좋은 인터랙티브 TUI (CPU spike 구간 캡처에 유리)
# - 패키지 목적
#   * openssh-server: SSH 데몬 (원격 진단 시뮬)
#   * ufw           : 방화벽 (네트워크 바인딩 조건 검증)
#   * acl           : setfacl/getfacl (로그/키 디렉터리 권한 분리)
#   * iproute2      : ss (포트 LISTEN 검증)
#                     ※ 24.04 minimal 에 기본 미포함 → 명시 설치
#   * sudo          : agent-admin 의 fine-grained sudo
#                     ※ 24.04 minimal 에 기본 미포함 → 명시 설치
#   * procps        : top / free / pgrep / ps  (CPU/MEM 관제, OOM 증거 수집)
#   * htop          : 대화형 프로세스 뷰어 (CPU 과점유 시각 증거)
#   * cron          : 자동 관제 주기 실행
#                     ※ 24.04 minimal 에 기본 미포함 → 명시 설치
#   * logrotate     : monitor.log 회전 (장시간 재현 시 로그 폭주 대비)
#   * vim/less/man-db: 매뉴얼 열람 및 편집 편의
FROM --platform=linux/amd64 ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Seoul \
    LANG=C.UTF-8

# Ubuntu 24.04 minimal 함정 해제 — base 이미지가 /usr/share/man/* 를
# dpkg path-exclude 로 설치 시점에 차단하고 있어 `man logrotate` 가 빈 응답.
# excludes 파일을 apt install *이전* 에 제거하면 이후 설치되는 패키지의
# manpage 가 정상적으로 디스크에 기록됨. (학습 단계의 man 페이지 가독성 확보)
RUN rm -f /etc/dpkg/dpkg.cfg.d/excludes

RUN apt-get update && apt-get install -y \
        openssh-server \
        ufw \
        acl \
        iproute2 \
        sudo \
        cron \
        procps \
        htop \
        logrotate \
        vim \
        less \
        man-db \
    && ln -sf /usr/share/zoneinfo/$TZ /etc/localtime \
    && rm -rf /var/lib/apt/lists/*

# Ubuntu 24.04 minimal 함정 해제 (2단) — base 이미지가 /usr/bin/man 을
# dpkg-divert 로 man.REAL 로 빼두고 그 자리에 안내 메시지만 출력하는
# 320 바이트 shell stub 을 박아둠. excludes 만 제거해서는 풀리지 않고,
# placeholder 를 먼저 지운 뒤 divert 를 --rename 으로 풀어야 진짜 man 복원.
RUN rm -f /usr/bin/man \
 && dpkg-divert --remove --rename /usr/bin/man

# sshd Privilege Separation 디렉터리 — Phase 1 트러블슈팅의 영구 해결
RUN mkdir -p /var/run/sshd

WORKDIR /app
CMD ["/bin/bash"]
