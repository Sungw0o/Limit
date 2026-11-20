# 배포 파이프라인 — 배포 잡당 3중 SSH 연결을 ControlMaster로 재사용

- 대상: GitLab CI `deploy_prod` / `monitoring_deploy_prod` / `rollback_prod` 잡이 순차 실행하는 배포 스크립트들의 SSH 연결 방식
- 작업일: 2026-08-11
- 기준 커밋: `05d1657` (dev, 성능 분석 하네스와 스킬 추가) 이후 워킹 트리 변경, **미커밋**
- 변경 파일: `scripts/deploy-remote.sh`, `scripts/sync-deploy-files.sh`, `scripts/apply-ci-s3-env-remote.sh`, `scripts/deploy-monitoring-remote.sh`, `scripts/rollback-remote.sh` (5개 모두 SSH 옵션에 `ControlMaster`/`ControlPersist`/`ControlPath` 3줄 추가)

---

## 0. 요약 (TL;DR)

`deploy_prod` 잡 하나가 `sync-deploy-files.sh` → `apply-ci-s3-env-remote.sh` → `deploy-remote.sh` 순서로 **서로 다른 SSH 연결을 3번** 연다(각각 독립적으로 TCP 핸드셰이크 + SSH 키 교환 + 공개키 인증을 처음부터 다시 수행). 이 프로젝트의 `.gitlab-ci.yml`/`Dockerfile.ci`는 이미 병렬 테스트, Gradle 캐시, jlink 커스텀 JRE, Trivy 캐시 재사용 등으로 깊이 최적화돼 있었고, 코드 조사 결과 배포 스크립트 쪽에서 유일하게 남아 있던, 근거 있는 개선 지점이 이 3중 SSH였다. `ssh -o ControlMaster=auto -o ControlPersist=60s`로 첫 연결을 재사용하도록 5개 스크립트를 고쳤고, 로컬 sshd(loopback, 실제 EC2 네트워크 왕복 시간은 포함하지 않음)로 30회 반복 측정한 결과 "3회 연속 SSH 호출" 왕복 시간이 평균 455.1ms → 169.6ms로 **62.7% 감소**했다. 실제 운영에서는 여기에 CI 러너↔EC2 간 실제 네트워크 왕복시간이 매 연결마다 추가로 얹히므로, 절감폭은 이 로컬 측정치보다 더 클 것으로 예상한다(가설 — 실측하지 못함, §12).

---

## 1. 문제 상황

`발표대본_시스템아키텍처_CICD.md`(이 프로젝트의 CI/CD 발표 대본)에 정리된 대로, 배포 파이프라인은 guard → test → quality → package → **deploy** → verify 6단계로 구성돼 있고, deploy 단계의 `deploy_prod` 잡은 `.gitlab-ci.yml:698-701`에서 세 스크립트를 순서대로 실행한다:

```yaml
script:
  - sh scripts/sync-deploy-files.sh
  - sh scripts/apply-ci-s3-env-remote.sh
  - sh scripts/deploy-remote.sh prod "$DEPLOY_IMAGE"
```

세 스크립트 모두 독립적으로 아래 패턴의 SSH 호출을 한 번씩 갖고 있었다(`sync-deploy-files.sh:29-35`, `apply-ci-s3-env-remote.sh:58-63`, `deploy-remote.sh:19-24`):

```sh
ssh -i "$DEPLOY_SSH_KEY_FILE" \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=yes \
  "$DEPLOY_USER@$DEPLOY_HOST" \
  "..."
```

`ControlMaster`/`ControlPersist` 옵션이 없어, 세 스크립트가 **같은 잡(같은 컨테이너, 같은 대상 호스트)** 안에서 실행되는데도 매번 새 TCP 연결을 맺고 SSH 프로토콜 협상·공개키 인증을 처음부터 반복한다. `monitoring_deploy_prod`(2개 스크립트: sync + deploy-monitoring-remote), `rollback_prod`(2개 스크립트: sync + rollback-remote)도 같은 패턴이다.

`.gitlab-ci.yml`과 `backend/Dockerfile.ci`를 먼저 검토한 결과 빌드/테스트 단계는 이미 병렬화·캐싱이 촘촘히 돼 있었고(§11 참고), 서브에이전트로 배포 스크립트 6곳(`deploy-blue-green.sh`, `deploy-remote.sh`/`sync-deploy-files.sh`, `smoke-test.sh`/`rollback-blue-green.sh`, `build-image.sh`, 런북/ADR, `compose.prod.yml`/`nginx` 설정)을 조사시킨 결과, 이 3중 SSH만이 "실측 가능하고 실제로 손볼 근거가 있는" 유일한 후보로 좁혀졌다 — 나머지는 이미 폴링 기반이거나(고정 `sleep` 없음), 캐시가 이미 적용돼 있거나, 문서에 별도로 기록된 가용성 트레이드오프(단일 EC2 한계, ADR-0002)였다.

---

## 2. 재현 환경

이번 후보는 HTTP API가 아니라 **배포 스크립트의 SSH 연결 비용**이라 k6/MySQL 기반 측정이 아니라, 로컬에 SSH 서버를 띄워 스크립트와 동일한 SSH 옵션·인증 방식으로 왕복 시간을 반복 측정하는 방식을 썼다.

| 항목 | 값 |
|---|---|
| 실행 환경 | 격리 리눅스 샌드박스 (Docker 미사용, rootless), 이전 실험들과 동일 머신 |
| SSH 서버 | OpenSSH 8.9p1 (`openssh-server`), `127.0.0.1:2222`에 로컬로 기동, 전용 ed25519 호스트키·클라이언트키 생성 |
| 인증 방식 | `BatchMode=yes`/`IdentitiesOnly=yes`/`StrictHostKeyChecking=yes` — 실제 배포 스크립트와 동일 옵션. `known_hosts`도 `ssh-keyscan`으로 미리 채워, `.gitlab-ci.yml`의 `install -m 644 "$SSH_KNOWN_HOSTS" ~/.ssh/known_hosts`(`deploy_prod.before_script`)와 동일한 사전 조건을 재현 |
| **중요한 제약** | 이 측정은 **loopback(127.0.0.1)**이라 실제 네트워크 왕복시간(RTT)이 사실상 0이다. 즉 "SSH 핸드셰이크·키 교환·인증 자체의 고정 비용"만 격리해서 보여주는 측정이고, CI 러너→실제 EC2 사이의 실제 네트워크 RTT(같은 리전이라도 수 ms~수십 ms)는 포함하지 않는다. 실제 배포에서는 연결마다 이 RTT가 여러 왕복(TCP handshake 1회, SSH 버전 교환 1회, 키 교환 2~3회, 인증 1~2회)만큼 추가로 곱해지므로, 실제 절감폭은 이 로컬 측정치보다 클 것으로 예상하지만 **이번 세션에서는 실제 EC2로 검증하지 못했다**(§12, `가설`) |
| 반복 횟수 | Before/After 각각 30회 (한 번의 trial = SSH 3회 연속 호출) |
| 측정 스크립트 | `evidence/ssh-controlmaster-bench.sh` |

---

## 3. Baseline (Before, 원본 스크립트 방식)

3개 스크립트가 각각 독립된 SSH 연결을 여는 원래 방식을, "같은 호스트에 SSH로 `true`를 3번 연속 실행"으로 재현했다(연결 대상이 다를 뿐 동일한 SSH 옵션·인증 절차).

| Metric | 값 |
|---|---:|
| 표본 수 | 30 trial (trial = SSH 3연속 호출의 총 왕복시간) |
| avg | 455.1 ms |
| stdev | 22.9 ms |
| min | 419.5 ms |
| p50 | 456.3 ms |
| p95 | 498.2 ms |
| max | 503.6 ms |

원본: `evidence/ssh-controlmaster-before-times.txt`.

---

## 4. 원인 분석

### 4-1. 매 SSH 호출마다 반복되는 고정 비용 (확정)

`ssh`는 연결마다 TCP 3-way handshake → SSH 프로토콜 버전 교환 → 키 교환(KEX, 보통 ECDH) → 호스트 키 검증(`known_hosts` 조회) → 공개키 인증(서명 생성/검증)을 수행한다. 이 전 과정이 각 연결마다 독립적으로 반복되며, `ControlMaster`가 없으면 같은 대상 호스트로의 반복 연결도 매번 이 과정을 새로 거친다 — OpenSSH 자체 문서에도 명시된 동작이다.

### 4-2. 왜 지금까지 감지되지 않았는가 (환경적 요인)

CI 러너와 배포 대상 EC2가 같은 리전(문서상 `ap-northeast-2`로 추정, ADR-0002 근거) 안에 있어 RTT 자체가 낮고, 배포는 dev/main 브랜치 푸시마다 한 번씩만 실행되는 저빈도 이벤트라 사람이 체감할 만큼 눈에 띄지 않았을 가능성이 크다(`가설`). §2에서 밝혔듯 로컬 측정은 RTT를 포함하지 않으므로, 이 항목이 실제 배포 시간에 정확히 얼마나 기여하는지는 이번 세션에서 확정하지 못했다.

---

## 5. 검토한 대안

| 대안 | 기대 효과 | 구현 복잡도 | 정합성/보안 영향 | 부작용/운영 위험 | 비고 |
|---|---|---|---|---|---|
| **A. `ControlMaster=auto` + `ControlPersist`로 연결 재사용 (채택)** | 첫 연결만 풀 핸드셰이크, 이후는 기존 소켓 재사용 — 로컬 측정 기준 3연속 호출 왕복시간 -62.7% | 낮음 (스크립트 5개에 `-o` 옵션 3줄씩 추가) | 없음 — 인증 방식(`BatchMode`/`IdentitiesOnly`/`StrictHostKeyChecking`)은 그대로, 재사용 여부만 바뀜 | `ControlPersist=60s` 동안 마스터 프로세스가 백그라운드에 남지만, CI 잡 컨테이너는 잡 종료와 함께 파기되므로 정리 부담 없음. `ControlPath`에 `%C`(호스트·유저·포트 해시)를 써서 배포 대상별로 소켓이 자동 분리되므로 다른 배포(dev/prod 등)와 섞일 위험 없음 | 이번 세션에서 채택 |
| B. 세 스크립트를 하나의 SSH 세션 안에서 실행되도록 통합(원격에 셸 스크립트 하나를 전송해 원격에서 순차 실행) | A와 유사하거나 더 큰 효과(연결 자체가 1번) | 높음 — 세 스크립트가 각자 다른 로컬 전처리(검증 정규식, tar 스트리밍, env 파일 생성)를 하고 있어 하나로 합치려면 로컬 로직과 원격 실행 로직을 다시 나눠야 함 | 스크립트 책임 분리가 무너져 개별 테스트(`sync-deploy-files.test.sh` 등)가 더 복잡해짐 | 기존 3개 스크립트의 독립적인 단위 테스트 가능성을 해치는 트레이드오프가 있어 이번 범위에서는 제외 | 다음 후보로 보류 |
| C. SSH 대신 원격 실행 도구(Ansible 등) 도입 | 연결 재사용 이상의 구조적 개선 가능 | 매우 높음 — 새 도구 도입, 파이프라인 전체 재작성 | 배포 스크립트 검증/테스트 전체를 다시 만들어야 함 | 이번 세션 범위를 크게 벗어남 | 제외 |

---

## 6. 의사결정

**A(`ControlMaster`/`ControlPersist` 연결 재사용)를 채택했다.**

- B(스크립트 통합)는 이론상 더 큰 효과(연결 1번)를 낼 수 있지만, 세 스크립트가 로컬 검증(`sync-deploy-files.sh`의 정규식 검증, `apply-ci-s3-env-remote.sh`의 제어문자 검사)과 원격 실행을 각각 책임지고 있어 통합하면 기존 단위 테스트(`sync-deploy-files.test.sh`, `apply-ci-s3-env-remote.test.sh`)를 다시 설계해야 한다. "가장 근거에 가까운 최소 변경" 원칙에 따라 제외했다.
- C(Ansible 등)는 이번 세션 범위를 크게 벗어나 제외했다.
- A는 SSH 옵션 3줄 추가로 끝나는 최소 변경이면서, 인증·보안 방식은 전혀 바꾸지 않고, 기존 스크립트 구조와 테스트를 그대로 유지할 수 있다.

---

## 7. 구현

5개 스크립트의 SSH 호출에 아래 3개 옵션을 추가했다:

```sh
ssh -i "$DEPLOY_SSH_KEY_FILE" \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=yes \
  -o ControlMaster=auto \
  -o ControlPersist=60s \
  -o ControlPath=/tmp/limit-deploy-ssh-%C \
  "$DEPLOY_USER@$DEPLOY_HOST" \
  "..."
```

- `ControlMaster=auto`: 마스터 연결이 없으면 새로 열고 마스터가 되며, 있으면 자동으로 재사용한다.
- `ControlPersist=60s`: 마지막 사용 후 60초간 마스터 연결을 백그라운드에 유지한다 — `deploy_prod` 잡의 세 스크립트가 보통 수 초~수십 초 안에 순차 실행되므로 이 창 안에서 재사용된다.
- `ControlPath=/tmp/limit-deploy-ssh-%C`: `%C`는 로컬호스트·원격호스트·포트·유저를 해시한 짧은 식별자라, 유닉스 소켓 경로 길이 제한(약 104자)에 안전하고 배포 대상이 다르면(예: 다른 EC2 호스트) 자동으로 다른 소켓을 쓴다.

적용 파일: `scripts/deploy-remote.sh`, `scripts/sync-deploy-files.sh`(`sync_archive` 함수), `scripts/apply-ci-s3-env-remote.sh`, `scripts/deploy-monitoring-remote.sh`, `scripts/rollback-remote.sh` — `deploy_prod`/`monitoring_deploy_prod`/`rollback_prod` 세 잡이 쓰는 모든 SSH 호출 스크립트를 빠짐없이 고쳤다(`.gitlab-ci.yml`의 잡 정의를 다시 확인해 5개가 전부임을 교차 확인).

**회귀 테스트:**

```
bash -n scripts/deploy-remote.sh                 # 문법 검사 통과
bash -n scripts/sync-deploy-files.sh             # 문법 검사 통과
sh   -n scripts/apply-ci-s3-env-remote.sh        # 문법 검사 통과
bash -n scripts/deploy-monitoring-remote.sh      # 문법 검사 통과
bash -n scripts/rollback-remote.sh               # 문법 검사 통과
bash scripts/sync-deploy-files.test.sh           # sync-deploy-files scope tests passed
bash scripts/apply-ci-s3-env-remote.test.sh      # CI S3 environment apply tests passed
sh   scripts/apply-ec2-env-remote.test.sh        # apply-ec2-env remote tests passed
```

세 `.test.sh`는 가짜 `ssh` 바이너리를 `PATH`에 심어 스크립트가 전달한 인자와 아카이브 내용을 검증하는 방식이라(`sync-deploy-files.test.sh:10-15`), 추가한 `-o ControlMaster=...` 등은 그대로 캡처될 뿐 기존 검증 로직(파일 목록, 원격 명령 문자열 검사)에 영향을 주지 않았다 — 3개 테스트 모두 수정 없이 그린이었다.

`scripts/ci-test.sh backend-scripts` 전체를 한 번에 실행하면 `operational-readiness.test.sh`의 정리(cleanup) 단계에서 `rm: Operation not permitted` 오류가 났는데, 이는 이번 변경과 무관한 **샌드박스 환경 자체의 파일시스템 권한 제약**이다(백업 시뮬레이션이 만든 파일을 Windows 마운트 경로에서 삭제하지 못함) — `backup-datastores.sh`/`operational-readiness.test.sh`는 이번에 손대지 않았고, 위 개별 테스트들은 문제 없이 통과했으므로 회귀가 아니라고 판단해 별도 조치하지 않았다(§12에 한계로 기록).

**측정 스크립트:** `evidence/ssh-controlmaster-bench.sh`

---

## 8. 검증

같은 로컬 sshd·같은 인증 절차·같은 30회 반복 조건에서, 수정본(ControlMaster 사용) 방식으로 재측정했다.

| Metric | 값 |
|---|---:|
| 표본 수 | 30 trial |
| avg | 169.6 ms |
| stdev | 10.6 ms |
| min | 149.9 ms |
| p50 | 169.5 ms |
| p95 | 185.9 ms |
| max | 186.6 ms |

원본: `evidence/ssh-controlmaster-after-times.txt`. 기능 회귀는 §7의 문법 검사·기존 단위 테스트 3건으로 확인했다.

---

## 9. Before / After

### SSH 3연속 호출 왕복 시간 (로컬 sshd, loopback, 30회 반복)

| Metric | Before | After | Change |
|---|---:|---:|---:|
| avg | 455.1 ms | 169.6 ms | **-62.7%** |
| p50 | 456.3 ms | 169.5 ms | **-62.9%** |
| p95 | 498.2 ms | 185.9 ms | **-62.7%** |
| max | 503.6 ms | 186.6 ms | -62.9% |
| stdev | 22.9 ms | 10.6 ms | - |

절대 절감폭은 trial당(=배포 잡 하나당) 평균 **285.5ms**다. 이는 순수하게 "SSH 연결 2개분의 핸드셰이크·인증을 생략한" 효과이며, §2에서 밝힌 대로 실제 네트워크 RTT는 포함하지 않은 수치다.

---

## 10. 결과 해석

`ControlMaster` 재사용은 3번의 독립 연결 중 2번의 TCP handshake·SSH KEX·공개키 인증을 완전히 생략하고 기존 유닉스 소켓으로 멀티플렉싱하는 것이므로, 개선 방향 자체는 이론과 정확히 일치한다 — 3연속 호출 시간이 대략 "연결 1회분 + 매우 저렴한 재사용 2회분"으로 줄어드는 것을 로컬 측정에서 그대로 확인했다(169.6ms ≈ 연결 1회 비용에 근접, 개별 SSH 연결 1회의 대략적 비용은 Before 평균 455.1ms/3 ≈ 151.7ms와 유사한 크기). 이 로컬 측정은 CI 러너가 EC2까지 갖는 실제 네트워크 왕복시간을 반영하지 못하므로, 실무에서 체감하는 절대 절감폭은 이보다 클 개연성이 높다(각 핸드셰이크가 요구하는 여러 차례의 왕복마다 실제 RTT가 곱해지기 때문) — 다만 이는 `가설`이며 이번 세션에서는 실제 EC2로 검증하지 못했다.

---

## 11. Trade-off

- `ControlPersist=60s` 동안 백그라운드에 SSH 마스터 프로세스가 남는다 — CI 잡 컨테이너는 잡이 끝나면 파기되므로 실제 위험은 없지만, 만약 이 스크립트들을 로컬 개발 머신 등 오래 유지되는 셸 세션에서 반복 실행한다면 소켓 파일(`/tmp/limit-deploy-ssh-*`)이 누적될 수 있다 — CI 전용 사용을 전제로 한 트레이드오프다.
- `ControlPath`가 `/tmp` 아래를 쓰므로, GitLab Runner의 잡 컨테이너가 `/tmp`를 쓰기 가능한 상태로 제공한다는 전제가 필요하다 — `alpine:3.22` 기반 `deploy_prod`/`rollback_prod`/`monitoring_deploy_prod` 이미지는 기본적으로 `/tmp`가 쓰기 가능하다고 알려져 있으나, 이번 세션에서는 실제 GitLab Runner 환경에서 직접 확인하지 못했다(§12).
- 이미 이 프로젝트의 CI/CD 파이프라인은 매우 성숙한 상태였고(§1), 이번 개선은 그 위에 남아 있던 "작지만 근거가 뚜렷한" 항목이라 절대적인 개선 폭(배포당 수백 ms 수준, 로컬 측정 기준)은 §9의 다른 두 후보(count 쿼리, 진단 요약 N+1)에 비해 작다 — 다만 배포 자체가 자주 일어나는 이벤트는 아니므로 "빈도 대비 효과"라는 관점에서 우선순위를 낮게 잡을 수 있다는 점을 함께 기록해 둔다.

---

## 12. 남은 한계

- **가장 중요한 한계**: 이 측정은 loopback(127.0.0.1) 기반이라 실제 네트워크 왕복시간(RTT)을 포함하지 않는다. CI 러너와 실제 배포 대상 EC2 사이의 실측 절감폭은 이번 세션에서 확인하지 못했다(`가설`: RTT가 있는 실제 환경에서는 절감폭이 이 로컬 측정치보다 클 것으로 예상하나, 정확한 배율은 모른다).
- 단일 실행(trial 30회, v1)만 수행했고, 날짜/시간을 달리한 반복 측정(v1/v2)으로 재현성을 재확인하지 않았다.
- `ControlPersist`가 실제 GitLab Runner의 컨테이너 파일시스템(`/tmp` 쓰기 가능 여부, 컨테이너 재사용 정책)에서 기대대로 동작하는지 실제 파이프라인에서 검증하지 못했다 — 다음 실제 배포(dev 브랜치 푸시)에서 파이프라인 로그의 각 스크립트 잡 소요 시간을 비교해 실측을 보완할 필요가 있다.
- `operational-readiness.test.sh` 등 이번에 손대지 않은 스크립트의 전체 `run_backend_scripts` 스위트를 끝까지 실행하지 못했다(§7의 샌드박스 파일시스템 권한 제약) — 개별 대상 테스트는 통과했지만, 스위트 전체가 그린인지는 실제 CI 러너에서 최종 확인이 필요하다.
- CPU/Memory 등 CI 러너 자체의 자원 사용량은 측정하지 않았다.
- 이 벤치마크는 `ssh ... "true"`처럼 아무 것도 하지 않는 원격 명령으로 측정했다 — 실제 스크립트는 원격에서 파일 압축 해제, 환경변수 파일 적용, blue-green 배포 스크립트 실행 등 추가 작업을 하므로, 그 작업 시간 자체는 이번 개선과 무관하게 그대로 남는다. 이번 개선은 어디까지나 "연결을 맺는 비용"만 줄인 것이다.

---

## 13. 포트폴리오 후보 문장

> 배포 파이프라인의 `deploy_prod` 잡이 SSH 연결을 3번(파일 동기화·환경변수 적용·blue-green 배포 실행) 독립적으로 여는 것을 코드로 확인하고, `ControlMaster`/`ControlPersist`로 첫 연결을 재사용하도록 5개 배포 스크립트를 수정했다. 로컬 SSH 서버로 30회 반복 측정한 결과 3연속 SSH 호출의 왕복 시간이 평균 455.1ms에서 169.6ms로 62.7% 감소(연결당 약 152ms 절감). 실제 EC2까지의 네트워크 왕복시간은 포함하지 않은 로컬 측정치이며, 실제 절감폭은 이보다 클 것으로 예상되나 검증하지 못했다.

수치는 실측값(로컬 loopback 조건)이며, "실제 EC2 환경 미검증"이라는 한계를 포트폴리오 본문에 반드시 함께 적을 것을 권장한다 — 이 문장만으로는 "실제 배포 시간이 몇 % 줄었다"는 인상을 주지 않도록 주의한다.

---

## 14. 포트폴리오 상세 작성용 자료

### 문제 상황 요약

이미 병렬 테스트·Gradle 캐시·jlink 최소 JRE·Trivy 캐시 재사용 등으로 깊이 최적화된 CI/CD 파이프라인에서, 배포 단계(deploy stage)만 검토가 안 돼 있었다. 배포 잡 하나가 파일 동기화, 환경변수 적용, blue-green 배포 실행을 서로 다른 스크립트 3개로 나눠 실행하는데, 각 스크립트가 독립적으로 SSH 연결을 새로 맺고 있었다.

### 의사결정 과정

세 스크립트를 하나로 합쳐 SSH 연결 자체를 1번으로 줄이는 방법도 검토했지만, 각 스크립트가 맡고 있는 로컬 검증·아카이브 생성 책임과 기존 단위 테스트 구조를 무너뜨리는 트레이드오프가 있어 제외했다. SSH 표준 기능인 `ControlMaster`/`ControlPersist`로 연결을 재사용하는 쪽이, 인증 방식이나 스크립트 구조를 전혀 바꾸지 않으면서 가장 적은 변경으로 같은 효과를 낼 수 있다고 판단했다.

### 해결

5개 배포 스크립트(`deploy-remote.sh`, `sync-deploy-files.sh`, `apply-ci-s3-env-remote.sh`, `deploy-monitoring-remote.sh`, `rollback-remote.sh`)의 SSH 호출에 `-o ControlMaster=auto -o ControlPersist=60s -o ControlPath=/tmp/limit-deploy-ssh-%C` 세 줄을 추가했다. 기존 인증 옵션(`BatchMode`/`IdentitiesOnly`/`StrictHostKeyChecking`)은 그대로 뒀다.

### 결과

로컬 SSH 서버로 30회 반복 측정한 결과, "SSH 3연속 호출" 왕복 시간이 평균 455.1ms → 169.6ms(-62.7%)로 줄었다. 다만 이 측정은 loopback이라 실제 네트워크 왕복시간을 포함하지 않으며, 실제 EC2 환경에서의 절감폭은 검증하지 못했다는 한계를 명확히 남겼다.

### 핵심 근거

- 관련 코드: `scripts/deploy-remote.sh`, `scripts/sync-deploy-files.sh`, `scripts/apply-ci-s3-env-remote.sh`, `scripts/deploy-monitoring-remote.sh`, `scripts/rollback-remote.sh`
- 관련 파이프라인 정의: `.gitlab-ci.yml`(`deploy_prod`, `monitoring_deploy_prod`, `rollback_prod` 잡)
- 관련 커밋: 없음 (워킹 트리 변경, 미커밋 — 기준 커밋 `05d1657`)
- 관련 테스트: `sync-deploy-files.test.sh`, `apply-ci-s3-env-remote.test.sh`, `apply-ec2-env-remote.test.sh` (모두 그린), 5개 스크립트 문법 검사(`bash -n`/`sh -n`) 통과
- 관련 측정 스크립트: `evidence/ssh-controlmaster-bench.sh`
- 관련 원본 결과: `evidence/ssh-controlmaster-before-times.txt`, `evidence/ssh-controlmaster-after-times.txt`, `evidence/ssh-controlmaster-summary.txt`
- 관련 문서: `발표대본_시스템아키텍처_CICD.md`, `docs/adr/0002-single-ec2-blue-green.md`, `docs/runbook/deployment.md`

---

## 다음 성능 개선 후보

1. **실제 EC2 환경에서의 재검증.** 이번 측정은 loopback 기준이라 실제 네트워크 RTT를 반영하지 못한다. 다음 배포(dev 브랜치 푸시) 때 GitLab CI 잡 로그의 `sync-deploy-files`/`apply-ci-s3-env-remote`/`deploy-remote` 각 스텝 소요 시간을 Before/After로 비교해 실측치를 보완할 필요가 있다.
2. **세 배포 스크립트의 원격 통합 실행(§5-B).** 로컬 검증 로직과 원격 실행 로직을 분리해서 재구성하면 SSH 연결을 1번으로 더 줄일 수 있지만, 기존 테스트 구조를 다시 설계해야 해서 이번엔 보류했다.
3. **product 도메인 잔여 병목** — `2026-08-10-product-list-verified-count-subquery.md` §14에서 이미 남겨둔 대로, 상품 목록/검색 API가 여전히 p95 4초대로 느리다(count 쿼리 서브쿼리 중복은 고쳤지만 구조적 한계가 남아 있음). 이번 세션에서 이어서 다룰지는 범위 확인이 필요하다.

> 노션 "취준/limit 개선사항" 페이지에 토글로 옮겨야 하는데, 이번 세션에서도 Notion 연동이 인증되어 있지 않아 직접 쓰지 못했습니다. 위 항목들을 그대로 토글로 붙여넣으시면 됩니다.
