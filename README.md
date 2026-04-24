# ops-scripts

메시지 서비스 인프라 운영 점검 자동화 스크립트

## 인프라 구성

| 서버 | 수량 | 역할 |
|---|---|---|
| Nginx | 1대 | 리버스 프록시, 모니터링 프록시 |
| Spring Boot | 2대 | 메시지 처리 애플리케이션 |
| Redis Cluster | 3노드 | 메시지 큐, 캐시 |
| MySQL | 2대 | Primary-Replica 복제 |
| 모니터링 서버 | 1대 | 점검 스크립트 실행 전용 |

## 네트워크 구조

모니터링 서버와 운영 서버는 네트워크가 분리되어 있습니다.

```
모니터링 서버
  ├── SSH(22)        → 모든 서버 직접 접근
  ├── HTTP(19100)    → Nginx 모니터링 프록시 (Actuator, Exporter)
  ├── SSH 터널       → Redis 6379
  └── SSH 터널       → MySQL 3306
```

## 파일 구조

```
ops-scripts/
├── conf/
│   ├── servers.conf.example    # 서버 접속 정보 템플릿 (servers.conf 직접 생성 필요)
│   └── thresholds.conf         # 임계값 설정
├── monitoring-server/          # 모니터링 서버에 배포
│   ├── common/
│   │   ├── inventory.sh        # conf 로더 + SSH/터널 함수
│   │   └── utils.sh            # 공통 유틸리티
│   ├── checks/
│   │   ├── check_nginx.sh
│   │   ├── check_springboot.sh
│   │   ├── check_redis_cluster.sh
│   │   └── check_mysql_repl.sh
│   ├── run_all_checks.sh       # 전체 점검 실행 진입점
│   ├── overnight_check.sh      # 야간 통합 분석 리포트
│   └── generate_report.sh      # LLM 기반 마크다운 보고서 생성
├── remote-agent/               # 대상 서버 8대에 배포
│   └── local_check.sh          # 로컬 정보 수집 (JSON 출력)
└── setup/
    ├── deploy.sh               # 초기 배포 자동화
    └── nginx_proxy.conf        # Nginx 프록시 설정 참고용
```

## 설치

### 1. 저장소 Clone

```bash
git clone https://github.com/621dev/ops-scripts.git /opt/ops-scripts
cd /opt/ops-scripts
```

### 2. servers.conf 생성

```bash
cp conf/servers.conf.example conf/servers.conf
vi conf/servers.conf
```

실제 서버 IP, SSH 포트, 터널 포트를 입력합니다.

### 3. 초기 배포

```bash
chmod +x setup/deploy.sh
bash setup/deploy.sh
```

deploy.sh 는 아래를 자동으로 처리합니다.

- SSH 키 생성
- 공개키 배포 안내
- `local_check.sh` 대상 서버 8대 배포
- SSH 터널 동작 테스트
- Actuator 프록시 응답 테스트

### 4. MySQL 점검 계정 생성

MySQL Primary 서버에서 실행합니다.

```sql
CREATE USER 'ops_check'@'%' IDENTIFIED BY 'YOUR_PASSWORD';
GRANT REPLICATION CLIENT, PROCESS, SELECT ON *.* TO 'ops_check'@'%';
GRANT SELECT ON performance_schema.* TO 'ops_check'@'%';
FLUSH PRIVILEGES;
```

모니터링 서버에 `~/.my.cnf` 생성합니다.

```ini
[client]
user     = ops_check
password = YOUR_PASSWORD
```

```bash
chmod 600 ~/.my.cnf
```

## 실행

### 전체 점검

```bash
bash /opt/ops-scripts/monitoring-server/run_all_checks.sh
```

### 특정 서버만

```bash
bash monitoring-server/run_all_checks.sh --role nginx
bash monitoring-server/run_all_checks.sh --role springboot
bash monitoring-server/run_all_checks.sh --role redis
bash monitoring-server/run_all_checks.sh --role mysql
```

> Redis / MySQL 은 반드시 `run_all_checks.sh` 를 통해 실행해야 SSH 터널이 자동으로 열립니다.

### 야간 점검

```bash
bash monitoring-server/overnight_check.sh
bash monitoring-server/overnight_check.sh --date 2024-01-15
bash monitoring-server/overnight_check.sh --role redis
```

### LLM 보고서 생성

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
bash monitoring-server/generate_report.sh
```

보고서는 `/var/log/ops-check/reports/report_{날짜}.md` 에 저장됩니다.

## 설정

### conf/servers.conf

서버 IP, SSH 포트, 터널 포트 등 환경별 접속 정보를 관리합니다.  
`.gitignore` 에 포함되어 있으므로 커밋되지 않습니다.  
`conf/servers.conf.example` 을 복사하여 사용합니다.

### conf/thresholds.conf

점검 임계값을 관리합니다. 스크립트 수정 없이 이 파일만 수정하면 됩니다.

| 항목 | 변수 | 기본값 |
|---|---|---|
| CPU 경고 | `SYS_CPU_WARN` | 70% |
| 메모리 경고 | `SYS_MEM_WARN` | 75% |
| JVM Heap 경고 | `SPRING_HEAP_WARN` | 75% |
| Redis 메모리 경고 | `REDIS_MEM_WARN` | 75% |
| 복제 지연 경고 | `MYSQL_REPL_LAG_WARN` | 30초 |
| 야간 시작 시각 | `OVERNIGHT_START` | 18:00 |
| 야간 종료 시각 | `OVERNIGHT_END` | 08:30 |

## Cron 등록

```cron
ANTHROPIC_API_KEY=sk-ant-...
MYSQL_OPS_PASS=your_password

# 개별 점검
*/15 * * * *  /opt/ops-scripts/monitoring-server/run_all_checks.sh --role nginx      >> /var/log/ops-check/cron_nginx.log  2>&1
*/10 * * * *  /opt/ops-scripts/monitoring-server/run_all_checks.sh --role springboot >> /var/log/ops-check/cron_spring.log 2>&1
*/10 * * * *  /opt/ops-scripts/monitoring-server/run_all_checks.sh --role redis      >> /var/log/ops-check/cron_redis.log  2>&1
*/10 * * * *  /opt/ops-scripts/monitoring-server/run_all_checks.sh --role mysql      >> /var/log/ops-check/cron_mysql.log  2>&1

# 야간 통합 분석 + 보고서 생성
30 8 * * *    /opt/ops-scripts/monitoring-server/generate_report.sh >> /var/log/ops-check/cron_report.log 2>&1
```

## 환경변수

| 변수 | 설명 |
|---|---|
| `ANTHROPIC_API_KEY` | Claude API 키 (보고서 생성 시 필요) |
| `REDIS_AUTH` | Redis AUTH 패스워드 |
| `MYSQL_OPS_PASS` | MySQL ops_check 패스워드 |
| `OPS_LOG_DIR` | 로그 저장 디렉토리 (기본: `/var/log/ops-check`) |