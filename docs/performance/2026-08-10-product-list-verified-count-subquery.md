# 상품 목록/검색 API — 검증개수 필터 count 쿼리 중복 서브쿼리 개선

- 대상 API: `GET /api/v1/products` (상품 목록/검색, `ProductApplicationService#findPublic`)
- 작업일: 2026-08-10
- 기준 커밋: `05d1657` (dev, 성능 분석 하네스와 스킬 추가) 이후 워킹 트리 변경, **미커밋**
- 변경 파일: `backend/src/main/java/com/c203/limit/domain/product/service/ProductApplicationService.java` (`verifiedCountBetween` 메서드)

---

> **개정 (2026-08-10, 2차):** 최초 작성 시 `k6` 기본 summary가 `p90`/`p95`만 내보내 **p99가 누락**됐고, HikariCP `active`/`idle`/`pending`, JVM Thread, 테스트 실행 시각도 기록하지 않았다. 하네스(`필수 결과`) 요구 항목이라 `--summary-trend-stats`에 `p(99)`를 추가해 **재측정**했고, 그 결과를 v2로 반영했다. v1(최초 측정)과 v2(재측정) 두 세트가 남아 있어 이를 그대로 "동일 조건 반복 측정"의 변동성 근거로도 같이 썼다(하네스: "하나의 실행만으로 결론내리지 않는다").

## 0. 요약 (TL;DR)

`minVerifiedCount`/`maxVerifiedCount`를 함께 쓰는 상품 목록 조회에서, Spring Data JPA `Specification` + `Pageable`이 자동 생성하는 **count 쿼리**가 동일한 상관 서브쿼리(체크리스트 완료 개수 COUNT)를 `>=`/`<=` 비교마다 **두 번 중복 실행**하고 있었다. `CriteriaBuilder.between()`으로 서브쿼리를 하나만 생성해 재사용하도록 바꿔, 같은 부하 조건(k6 20VU/60s, 5만 건 시드 데이터)에서 p95 응답시간을 7.17s → 4.03s로 낮췄다(43.8% 감소, p99 기준 7.96s → 4.42s, -44.5%). 같은 조건으로 2회씩(v1/v2) 반복 측정했고 두 세트 모두 35~53% 구간의 유사한 개선폭을 보여 재현성을 확인했다. 남은 병목(코드 미변경, 다음 후보로 분류)도 §12/§14에 기록했다.

이 실험 과정에서 **벌크 시드 직후 InnoDB 통계 미갱신**이 그 자체로 p95를 11.69s → 6.42s(45.2%)까지 낮추는 별도 요인임을 확인했다. 이는 운영 환경에서 지속적으로 갱신되는 통계와는 조건이 다른, 이번 테스트 데이터 적재 방식에 따른 아티팩트일 가능성이 커서 "코드 개선 효과"와는 분리해 §4/§11에 별도로 기록했다.

---

## 1. 문제 상황

`ProductApplicationService.findPublic()`은 `ListingRepository extends JpaSpecificationExecutor<Listing>`의 `findAll(spec, pageable)`을 호출한다. 이 메서드는 Spring Data JPA 관례상 페이지네이션을 위해 **content 쿼리 + count 쿼리**를 각각 별도로 실행한다.

목록 필터 중 `verifiedCountBetween(min, max)`은 "완료된 필수 체크리스트 항목 개수"를 세는 상관 서브쿼리 하나(`completedQuery`)를 만들어 두고, `min`/`max` 조건을 각각 `cb.greaterThanOrEqualTo(completedQuery, min)`과 `cb.lessThanOrEqualTo(completedQuery, max)`로 걸었다. JPA Criteria API에서 같은 `Subquery` 객체를 두 Predicate에서 참조해도, Hibernate가 최종 SQL로 변환할 때는 **상관 서브쿼리를 각 비교식마다 독립적으로 풀어써서 SQL에 두 번 나타난다.** 즉 코드상으로는 "한 번 정의해서 재사용"처럼 보이지만 실제 실행되는 SQL과 실행 횟수는 두 배다.

이 문제는 코드만 봐서는 실제 영향도를 확정할 수 없어 최초엔 `가설`로만 분류했고(§ 이전 서브에이전트 조사 결과: 후보 1위, `ProductApplicationService.java:866-891`), 아래 Baseline 측정과 `EXPLAIN`, slow query log로 실제 발생 여부와 비용을 확인했다.

---

## 2. 재현 환경

Docker를 사용할 수 없는 격리 샌드박스(비루트, privileged 불가)였기 때문에 아래와 같이 대체 구성했다. **운영 환경과 스펙이 다르므로 절대값이 아니라 Before/After 상대 비교로만 사용한다.**

| 항목 | 값 |
|---|---|
| 실행 환경 | 격리 리눅스 샌드박스 (Docker 미사용, rootless) |
| CPU | 2 vCPU |
| Memory | 3.8 GB (전체, MySQL+App+k6 공유) |
| Java | Temurin 21.0.12 (프로젝트 `toolchain` 요구사항) |
| Spring Boot | 4.0.7 |
| DB | MySQL 8.0.39 Community, 제네릭 tarball, rootless 실행 (포트 3307) |
| InnoDB buffer pool | 768MB |
| 애플리케이션 인스턴스 수 | 1 (java -jar, `-Xms512m -Xmx768m`) |
| MongoDB / Redis | 미기동 (제품 목록/검색 경로는 미사용 확인, 코드 검색 결과 `MongoRepository`/`@Document`/`RedisTemplate` 사용 없음). 앱은 연결 실패를 경고 로그만 남기고 정상 기동 |
| Connection Pool | HikariCP 기본값, `maximumPoolSize=10` (애플리케이션 기본 설정 그대로, 별도 튜닝 없음) |
| Cache 상태 | MySQL 쿼리 캐시 없음(8.0). Before/After 모두 warm-up 요청 1회 후 측정(동일 절차) |
| 테스트 데이터 규모 | `listing` 50,000행 (status=ON_SALE), `listing_checklist_item` 255,806행 (평균 5.1개/상품), `listing_image` 150,000행, `seller` 500 / `user_account` 500, 카테고리 43개(발행된 체크리스트 템플릿 보유) |
| k6 버전 | v0.54.0 |
| k6 VU | 20 (constant-vus) |
| k6 duration | 60s + drain |
| think time | 200ms/iteration |
| 테스트 endpoint | `GET /api/v1/products` — 40% `keyword` 단독, 30% `keyword`+`minVerifiedCount=1`+`maxVerifiedCount=4`, 30% 필터 없는 페이지 브라우징 (스크립트: `evidence/k6-product-list.js`) |
| 기타 | slow_query_log 전체 활성화(`long_query_time=0`)로 모든 쿼리 기록, `log_queries_not_using_indexes=1` |

시드 데이터는 SQL 배치 삽입(`INSERT ... SELECT`)으로 생성했다(재현 스크립트: `evidence/seed.sql`). 판매자/카테고리/키워드는 모듈로 분산으로 결정론적으로 배정했고, 체크리스트 완료 상태(`completion_status`)는 `MOD(listing_id + template_item_id, 5)`로 약 60%는 COMPLETED, 20%는 PENDING, 20%는 IN_PROGRESS가 되도록 분산시켰다.

---

## 3. Baseline

**주의:** 아래 "Before"는 코드 수정 전 상태를 InnoDB 통계가 최신인 조건(벌크 시드 후 `ANALYZE TABLE` 1회 실행)에서 다시 측정한 값이다. 최초 Baseline(통계 미갱신 상태)은 훨씬 나빴고 §4에 별도 기록했다 — 코드 변경 효과와 통계 갱신 효과를 분리하기 위해서다.

### Before (수정 전, ANALYZE 이후 동일 조건) — v1 / v2 반복 측정

같은 조건으로 두 번 반복 측정했다(하네스: 단일 실행으로 결론내리지 않기 위함). v2는 `p99`, HikariCP `active`/`idle`/`pending`, JVM Thread, 실행 시각까지 포함해 재측정한 것이다.

| Metric | v1 (최초) | v2 (p99 포함 재측정) |
|---|---:|---:|
| 실행 시각(UTC) | 기록 안 함 (§12 한계로 인정) | 2026-08-10T08:11:45Z ~ 08:12:49Z |
| 요청 수 | 372건 | 331건 |
| RPS | 5.97 req/s | 5.18 req/s |
| avg | 3.10 s | 3.53 s |
| p50(med) | 2.44 s | 2.67 s |
| p90 | 5.59 s | 6.57 s |
| p95 | 6.42 s | 7.17 s |
| p99 | 측정 안 함(N/A, k6 기본 trend stats에 p99 미포함) | 7.96 s |
| max | 8.46 s | 8.71 s |
| Error rate | 0.00% | 0.00% |
| HikariCP acquire avg | 1.43 s | 1.60 s (540.33s / 337건) |
| HikariCP acquire max | 3.86 s | 4.34 s |
| HikariCP usage avg (커넥션 점유 시간) | 측정 안 함 | 1.87 s (628.53s / 337건) |
| HikariCP usage max | 측정 안 함 | 5.49 s |
| HikariCP active/idle/pending | 측정 안 함 | 0 / 10 / 0 (테스트 **종료 후** 스냅샷 — 부하 중 값이 아니라 참고용, §12) |
| JVM Threads live | 측정 안 함 | 47 |
| HikariCP pool size | 10 (기본값, 변경 없음) | 10 |

v1↔v2 간 p95 차이(6.42s vs 7.17s, 약 11.7%)는 같은 코드·같은 조건에서도 이 정도의 실행 간 변동이 있다는 뜻이다 — 이후 개선율 해석 시 오차 범위로 감안한다.

원본 k6 결과: `evidence/before_summary.json`(v1), `evidence/before_v2_summary.json`(v2)

### 참고: 최초 Baseline (통계 미갱신 상태, 코드도 수정 전)

| Metric | 값 |
|---|---:|
| 요청 수 | 154건 |
| RPS | 2.30 req/s |
| avg | 8.10 s |
| p95 | 11.69 s |
| max | 12.93 s |
| HikariCP acquire (avg) | 3.74 s (601.85s / 161건) |
| HikariCP acquire (max) | 6.95 s |

원본: `evidence/baseline_pre_analyze_summary.json`. 이 값은 §11(Trade-off)/§12(한계)에서만 참고용으로 인용하며, 공식 Before/After 비교에는 사용하지 않는다(비교 가능 조건 위반 — 통계 상태가 다름).

---

## 4. 원인 분석

### 4-1. count 쿼리 중복 서브쿼리 (코드 결함 — 확정)

Slow query log(`long_query_time=0`)에서 `keyword`+`minVerifiedCount`+`maxVerifiedCount` 조합 요청의 count 쿼리가 반복적으로 3.8~4.3s를 기록했다(`evidence/before_count_query_sample.sql`의 전신 로그, 통계 미갱신 시점 원본 캡처). 해당 쿼리의 `EXPLAIN FORMAT=TREE`:

```
-> Aggregate: count(l1_0.id)
    -> Filter: (title LIKE OR category.name LIKE OR category.manufacturer LIKE)
        -> Nested loop left join
            -> Filter: (deleted_at is null AND moderation_status IN (...)
                        AND (select #2) >= 1 AND (select #3) <= 4)
                -> Index lookup on l1_0 using idx_listing_status (status='ON_SALE')
                -> Select #2 (subquery in condition; dependent) -> count(...) WHERE listing_id=l1_0.id ...
                -> Select #3 (subquery in condition; dependent) -> count(...) WHERE listing_id=l1_0.id ...
```

`Select #2`, `Select #3`가 **완전히 동일한 조건**(`is_required AND completion_status='COMPLETED' AND listing_id=l1_0.id`)의 별개 서브쿼리로 두 번 나타난다. `ANALYZE TABLE` 이후 재현한 단일 쿼리 실행(위 EXPLAIN과 동일 SQL, warm cache, 동시성 없음)에서:

- 원본(2-서브쿼리, `>=` AND `<=`): 0.754s
- `BETWEEN` 단일 서브쿼리로 수동 재작성: 0.516s (-31.6%)

이 측정은 **격리된 단일 쿼리** 조건이라 동시 부하(20VU) 하에서의 절대 수치와는 다르지만, "서브쿼리가 두 번 실행되는 것이 실측 가능한 비용 차이를 만든다"는 근거로는 유효하다. 최종 판단 근거는 §8 k6 재측정과 §4-3 slow log 비교다.

### 4-2. HikariCP 커넥션 풀 대기 (증상, 근본 원인 아님)

`hikaricp_connections_acquire_seconds`가 Before에서 평균 1.43s, 최대 3.86s로 나타났다(20VU가 `maximumPoolSize=10`을 두고 경합). 이는 count/detail 쿼리 자체가 느려 커넥션 점유 시간이 길어진 **결과**이지, 풀 크기 자체의 결함은 아니다 — 풀을 키우는 것은 이번 변경 범위에서 제외했다(§5, §6 참고).

### 4-3. 통계 미갱신 (환경 요인 — 코드 문제 아님, 이번 실험 한정 관찰)

같은 count 쿼리를 `ANALYZE TABLE listing, category, listing_checklist_item, listing_image` 실행 전/후로 비교:

- 실행 전 `EXPLAIN`: `idx_listing_status` 조회의 행수 추정치가 **1행**으로 나타남(실제 ON_SALE 행은 50,000행)
- 실행 후 `EXPLAIN`: 동일 조회의 추정치가 **24,543행**으로 정정됨
- k6 p95: 11.69s → 6.42s (45.2% 감소, 코드 변경 없이 통계 갱신만으로)

이건 대량 `INSERT ... SELECT` 벌크 적재 직후 InnoDB 영속 통계(`innodb_stats_persistent`)가 자동 재계산되기 전 상태를 그대로 측정에 노출시킨 것으로 보인다(`가설` — MySQL 자동 통계 재계산 임계치(테이블의 10% 변경)에 도달하기 전 시점이었을 가능성). 운영 환경은 트래픽이 점진적으로 쌓이므로 이런 극단적 괴리는 흔치 않을 것으로 추정되지만, **대량 배치 적재/마이그레이션 직후에는 반드시 `ANALYZE TABLE`을 운영 절차에 포함해야 한다**는 것은 이번 실험에서 확인된 사실이다. 이 관찰은 §14 "다음 후보"가 아니라 운영 체크리스트 항목으로 별도 제안한다(§11).

### 4-4. 남은 병목 (기각하지 않음, 이번엔 손대지 않음)

`ANALYZE TABLE` 이후에도 `EXPLAIN` 트리 구조 자체는 바뀌지 않았다 — 옵티마이저는 여전히 상관 서브쿼리 필터를 **LIKE 필터보다 먼저**, ON_SALE 전체 후보(약 24,543행)에 대해 평가한다. 즉 키워드가 상품 10%만 걸러내는 조건이어도 서브�큐리는 24,543번 실행된다. `BETWEEN` 수정은 "행당 서브쿼리 실행 횟수"를 2회→1회로 줄였을 뿐, "행 자체가 몇 번 평가되는가"는 그대로다. 이게 After에서도 p95가 3.93s로 여전히 느린 이유다(§12).

---

## 5. 검토한 대안

| 대안 | 기대 성능 | 구현 복잡도 | 정합성 영향 | 부작용/운영 위험 | 비고 |
|---|---|---|---|---|---|
| **A. `BETWEEN`으로 중복 서브쿼리 제거 (채택)** | count 쿼리 서브쿼리 실행 2회→1회. 실측 p95 -38.7% | 낮음 (메서드 1개, 10줄) | 없음 (동일 조건, 결과 동일 — `totalElements=3489` 수동 SQL과 일치 확인) | 없음. API 응답 스키마·프론트 변경 불필요 | `min`/`max` 둘 다 있을 때만 적용, 단일 조건은 기존 로직 유지 |
| B. `Page` → `Slice` 전환 (count 쿼리 자체 제거) | 이론상 가장 큼 (count 쿼리 왕복 자체가 사라짐) | 중간 (Repository/Service 반환 타입 변경) | **API 계약 변경** — `totalElements`/`totalPages` 사라짐 | 프론트 `ProductListPage.vue`가 `pageMeta.totalPages`로 페이지 번호 UI(`1/N`), `totalElements`로 "N개 상품" 카운트를 표시 중(`frontend/src/pages/ProductListPage.vue:68,120,474-492`) — 프론트 동시 수정 없이는 배포 불가 | 다음 후보로 보류 (§14) |
| C. 키워드 검색에 FULLTEXT 인덱스 적용, `LIKE` → `MATCH...AGAINST` | LIKE 자체 비용 감소 + 옵티마이저가 인덱스 조건을 먼저 평가할 가능성 | 높음 (마이그레이션, boolean mode 파싱 차이로 검색 동작 변경 가능성 검증 필요) | 검색 결과가 미묘하게 달라질 위험(부분 문자열 vs 형태소/단어 매칭) | 검증 범위가 커서 이번 1건 처리 범위를 벗어남 | 다음 후보로 보류 (§14) |
| D. `ANALYZE TABLE` 정기 실행/운영 절차화 | 이번 실험에서 통계 자체만으로 -45.2% 관찰 | 낮음 (운영 스크립트) | 없음 | MySQL 버전에 따라 `ANALYZE TABLE`이 짧게 테이블 락을 유발할 수 있음(운영 시간대 고려 필요) | 코드 변경이 아니라 운영 체크리스트로 별도 제안 (§11) |

---

## 6. 의사결정

**A(중복 서브쿼리 제거)를 선택했다.**

- B(Slice 전환)가 이론상 더 큰 효과를 낼 수 있지만, 프론트엔드 페이지 번호 UI와 "N개 상품" 표시가 `totalElements`/`totalPages`에 실제로 의존하고 있어(§5 표, 코드 근거 포함) 백엔드 단독 변경으로 안전하게 배포할 수 없다. 이번 작업은 "가장 근거에 가까운 최소 변경"을 원칙으로 했으므로, 프론트 동시 변경이 필요한 B는 범위를 벗어난다고 판단해 제외했다. B는 §14 다음 후보로 남긴다.
- C(FULLTEXT)는 검색 결과의 의미(부분 문자열 매칭 vs 형태소 매칭)가 달라질 수 있어 회귀 위험이 A보다 훨씬 크고, 검증에 필요한 작업량(마이그레이션 + 검색 결과 비교 테스트)이 이번 세션의 근거 확보 범위를 넘어선다고 판단해 제외했다.
- D(ANALYZE TABLE 운영화)는 코드 변경이 아니라 별도 운영 이슈로 분리했다 — 이번 발견을 근거로 배포/마이그레이션 런북에 반영을 제안하되, 이번 "코드 변경 1건" 완료 보고의 범위에는 포함하지 않았다.
- A는 EXPLAIN으로 재현 가능한 명확한 원인(동일 조건 서브쿼리 중복)을 갖고 있고, API 계약을 전혀 바꾸지 않으며, 변경 범위가 메서드 1개로 국한돼 회귀 위험이 가장 낮다. 다만 §4-4에서 밝혔듯 이 변경만으로는 문제를 완전히 해결하지 못한다 — "가장 직접적인 근거가 있는 최소 변경"이라는 원칙과 "해결"이라는 표현을 구분해서 §12/§14에 명시했다.

---

## 7. 구현

**변경 파일:** `backend/src/main/java/com/c203/limit/domain/product/service/ProductApplicationService.java`

`verifiedCountBetween(Integer min, Integer max)`에서 `min`과 `max`가 모두 주어진 경우, 기존의 `greaterThanOrEqualTo` + `lessThanOrEqualTo` 두 Predicate(서로 다른 서브쿼리 SQL 두 개 생성) 대신 `cb.between(completedQuery, min, max)` 하나로 묶어 서브쿼리가 SQL에 한 번만 나타나도록 했다. `min`/`max` 중 하나만 있는 경우는 기존 로직을 그대로 유지한다(원래도 서브쿼리 1개).

```java
if (min != null && max != null) {
    return cb.between(completedQuery, min.longValue(), max.longValue());
}
var predicate = cb.conjunction();
if (min != null) {
    predicate = cb.and(predicate, cb.greaterThanOrEqualTo(completedQuery, min.longValue()));
}
if (max != null) {
    predicate = cb.and(predicate, cb.lessThanOrEqualTo(completedQuery, max.longValue()));
}
return predicate;
```

**테스트:** 기존 회귀 테스트 실행 (신규 테스트는 추가하지 않음 — 기존 `ProductApplicationServiceTests`가 `Mockito`로 `listingRepository`를 모킹하고 있어 실제 Criteria/SQL 생성은 검증하지 못한다는 한계가 있음, §12 기록):

```
./gradlew test --tests "com.c203.limit.domain.product.service.ProductApplicationServiceTests" \
               --tests "com.c203.limit.domain.product.controller.ProductMockControllerTests"
BUILD SUCCESSFUL
```

**기능 정합성 수동 검증:** 실제 MySQL에 대해 `keyword=iphone&minVerifiedCount=1&maxVerifiedCount=4`로 호출한 응답의 `totalElements=3489`가, 수정 전 두-서브쿼리 SQL을 수동 실행한 결과(`count(l1_0.id)=3489`)와 동일함을 확인했다 — 결과 집합이 바뀌지 않았다는 근거.

**k6 스크립트:** `evidence/k6-product-list.js` (Before/After 동일 스크립트, VU/duration 고정)
**시드 스크립트:** `evidence/seed.sql`

---

## 8. 검증

Before와 동일한 조건(같은 시드 데이터, 같은 `ANALYZE TABLE` 이후 통계 상태, 같은 k6 스크립트/VU/duration, 새로 기동한 앱 프로세스·MySQL 프로세스)에서 재측정했다. Before와 마찬가지로 v1/v2 두 번 반복했다.

| Metric | v1 (최초) | v2 (p99 포함 재측정) |
|---|---:|---:|
| 실행 시각(UTC) | 기록 안 함 | 2026-08-10T08:13:25Z ~ 08:14:28Z |
| 요청 수 | 567건 | 531건 |
| RPS | 9.12 req/s | 8.53 req/s |
| avg | 1.95 s | 2.10 s |
| p50(med) | 1.56 s | 1.64 s |
| p90 | 3.53 s | 3.79 s |
| p95 | 3.93 s | 4.03 s |
| p99 | 측정 안 함(N/A) | 4.42 s |
| max | 5.41 s | 4.76 s |
| Error rate | 0.00% | 0.00% |
| HikariCP acquire avg | 0.86 s | 0.92 s (494.73s / 537건) |
| HikariCP acquire max | 2.80 s | 2.81 s |
| HikariCP usage avg | 측정 안 함 | 1.14 s (614.19s / 537건) |
| HikariCP usage max | 측정 안 함 | 3.33 s |
| HikariCP active/idle/pending | 측정 안 함 | 0 / 10 / 0 (테스트 종료 후 스냅샷, §12) |
| JVM Threads live | 측정 안 함 | 47 (Before와 동일 — 스레드 수는 이번 변경으로 영향 없음) |

원본 k6 결과: `evidence/after_summary.json`(v1), `evidence/after_v2_summary.json`(v2)

기능 회귀는 §7에서 별도 확인했고, 기존 단위 테스트는 그린이다.

---

## 9. Before / After

아래는 **v2(p99 포함 재측정)** 값을 기준으로 한다. v1은 §3/§8에 별도로 남겨뒀고, v1↔v2 간 개선율도 같은 방향(35~53% 구간)이라 재현성이 있는 것으로 판단한다.

### HTTP 레벨 (`GET /api/v1/products`, k6, 20VU/60s)

| Metric | Before (v2) | After (v2) | Change |
|---|---:|---:|---:|
| avg | 3.53 s | 2.10 s | -40.5% |
| p50 | 2.67 s | 1.64 s | -38.6% |
| p90 | 6.57 s | 3.79 s | -42.3% |
| p95 | 7.17 s | 4.03 s | -43.8% |
| p99 | 7.96 s | 4.42 s | -44.5% |
| max | 8.71 s | 4.76 s | -45.4% |
| RPS | 5.18 | 8.53 | +64.7% |
| Error Rate | 0.00% | 0.00% | - |
| 완료 iteration 수 (60s+drain) | 331 | 531 | +60.4% |

참고(v1, 재측정 전): avg -37.1%, p95 -38.7%, RPS +52.6% — v2와 방향·크기가 유사하다.

### DB 레벨 (count 쿼리, `keyword`+`minVerifiedCount`+`maxVerifiedCount` 조합, slow query log 전수 집계, v2)

| Metric | Before (v2) | After (v2) | Change |
|---|---:|---:|---:|
| n (표본 수) | 332 | 532 | - |
| avg | 1.712 s | 1.021 s | -40.4% |
| p50 | 0.529 s | 0.521 s | -1.5% (측정 노이즈 범위) |
| p95 | 4.365 s | 2.708 s | -38.0% |
| p99 | 4.511 s | 2.852 s | -36.8% |
| max | 5.154 s | 3.038 s | -41.1% |

### 애플리케이션 레벨 (v2)

| Metric | Before (v2) | After (v2) | Change |
|---|---:|---:|---:|
| HikariCP acquire avg | 1.603 s | 0.921 s | -42.5% |
| HikariCP acquire max | 4.340 s | 2.815 s | -35.1% |
| HikariCP usage avg (커넥션 점유 시간) | 1.865 s | 1.144 s | -38.7% |
| HikariCP usage max | 5.491 s | 3.331 s | -39.3% |
| HikariCP active/idle/pending (테스트 종료 후 스냅샷) | 0 / 10 / 0 | 0 / 10 / 0 | 변화 없음 — 부하 종료 후 값이라 부하 중 포화 여부는 이 지표로 못 봄(§12) |
| HikariCP pool size | 10 (미변경) | 10 (미변경) | - |
| JVM Threads live | 47 | 47 | 변화 없음 |
| DB round-trip 수 / 요청 | 변화 없음 (count 1 + content 1 + 배치 메트릭 쿼리, §10) | 변화 없음 | - |
| CPU / Memory / JVM Heap / GC | N/A (샌드박스에 시계열 모니터링 미구성) | N/A | 측정 안 함 |

---

## 10. 결과 해석

이번 변경은 **쿼리 왕복 횟수를 줄인 것이 아니라, count 쿼리 하나 안에서 반복 실행되던 상관 서브쿼리의 실행 횟수를 행당 2회에서 1회로 줄인 것**이다. `EXPLAIN`에서 `Select #2`/`Select #3` 두 개였던 의존 서브쿼리가 `Select #2` 하나(`BETWEEN`)로 줄었고, ON_SALE 전체 후보군(약 24,543행) × 서브쿼리 1회라는 구조 자체는 그대로다. 그 결과:

- count 쿼리 자체의 실행 비용이 크게 줄었고(p95 -38.0%, DB 레벨, v2 기준)
- count 쿼리가 HikariCP 커넥션을 붙잡고 있는 시간(usage)이 줄어(usage avg -38.7%) 20VU 동시 요청에서의 **커넥션 획득 대기**도 함께 줄었으며(acquire avg -42.5%)
- 그 결과 HTTP 레벨 p95도 -43.8%로, DB 단일 쿼리 개선폭과 비슷하거나 조금 더 크게 나타났다 — 커넥션 경합이라는 승수 효과가 더해진 것으로 해석한다(`가설`: 정확한 인과 기여도 분리는 하지 않았음, HikariCP acquire/usage 지표로 방향성만 뒷받침).

즉 "Full Scan → Index Range Scan"이나 "쿼리 수 감소"류의 개선은 아니고, **"동일한 서브쿼리의 중복 실행 제거"**가 이번 개선의 정확한 기술적 이유다.

---

## 11. Trade-off

- 없음에 가깝다. `cb.between()`은 `min`/`max`가 둘 다 있을 때만 타는 분기이고, 결과 집합·API 응답 스키마는 동일하다.
- 굳이 꼽자면 코드 가독성 관점에서 "두 조건을 각각 명시"하던 것을 "범위 비교 하나"로 묶어 조건 분기가 하나 늘었다 — 유지보수 비용은 미미하다.
- §4-3에서 발견한 `ANALYZE TABLE` 관련 사실은 이번 코드 변경과 무관하지만, 운영 절차에 반영을 제안한다: 대량 배치 적재/마이그레이션 직후 `ANALYZE TABLE`을 명시적으로 실행하는 단계를 배포·마이그레이션 런북에 추가할 것을 권고한다(`docs/runbook/deployment.md` 검토 필요 — 이번 세션에서는 미반영, 운영팀 판단 필요).

---

## 12. 남은 한계

- **문제를 완전히 해결하지 못했다.** After에도 p95 4.03s(p99 4.42s)는 사용자 응답 시간 기준으로 여전히 느리다. 근본 원인(§4-4)은 옵티마이저가 상관 서브쿼리를 LIKE 필터보다 먼저, ON_SALE 전체 후보(약 24,543행)에 대해 평가하는 구조이며, 이번 변경은 그 실행 횟수를 절반으로 줄였을 뿐 구조 자체를 바꾸지 않았다.
- 단일 EC2/샌드박스 환경(2 vCPU, 3.8GB, Docker 미사용, MySQL+App+k6 동일 머신)에서만 측정했다 — 운영 인프라(별도 DB 인스턴스, 더 많은 코어, 실제 네트워크 왕복)와 조건이 다르다.
- k6를 애플리케이션·DB와 같은 머신에서 실행해 k6 자체의 CPU 사용이 측정값에 다소 잡음을 더했을 수 있다(`가설`, 별도 격리 측정은 하지 않음).
- CPU/Memory/JVM Heap/GC/DB CPU는 측정하지 못했다(N/A) — 샌드박스에 Prometheus/Grafana 등 시계열 모니터링을 구성하지 않았고, 이번 세션 범위에서는 HikariCP 지표와 slow query log만으로 근거를 구성했다.
- HikariCP `active`/`idle`/`pending`은 **부하 테스트가 끝난 뒤** `/actuator/prometheus`를 스크레이프한 스냅샷이라 Before/After 모두 `0/10/0`으로 동일하게 나온다 — 실제로 부하 중 커넥션이 얼마나 포화됐는지는 이 지표로 보여주지 못한다. 부하 중 상태를 보려면 테스트 도중 주기적으로 스크레이프하거나 Prometheus를 붙여 시계열로 남겨야 하는데, 이번엔 하지 않았다. 대신 누적 분포 지표인 `acquire_seconds`/`usage_seconds`(합계·최댓값)는 테스트 전 구간 누적이라 유효한 근거로 썼다.
- 같은 조건 반복 측정(v1, v2)에서 p95가 6.42s~7.17s 사이로 흔들렸다 — 원인을 별도로 분리하지 않았다(`가설`: 샌드박스 공유 CPU 2코어에서 MySQL+App+k6가 동시에 도는 구조상 실행마다 스케줄링 편차가 있었을 가능성). 개선율은 이 변동 폭(약 10%p) 안에서 읽어야 한다.
- 실제 운영 트래픽 패턴(브라우저 캐시, CDN, 실사용자 키워드 분포)과 다른 합성 데이터·합성 부하 패턴이다.
- Redis/MongoDB를 기동하지 않고 측정했다 — 코드 검색으로 상품 목록/검색 경로가 이 둘을 쓰지 않음을 확인했지만(§2), 연결 재시도 로그 자체가 미세한 CPU 오버헤드를 더했을 가능성은 배제하지 않았다(`가설`).
- 기존 단위 테스트가 Repository를 모킹하고 있어, 이번 Criteria 변경이 생성하는 실제 SQL을 코드 차원에서 자동 검증하는 테스트가 없다 — 이번엔 수동으로 MySQL에 직접 질의해 결과 일치를 확인하는 방식으로 대체했다. 회귀 방지를 위해 실제 DB(H2 또는 Testcontainers)를 사용하는 슬라이스 테스트 추가가 필요하다(다음 작업 후보로 별도 관리 필요, 이번 세션 범위 밖).
- `ANALYZE TABLE`의 효과(§4-3)를 정상 운영 트래픽 환경에서는 검증하지 못했다 — 벌크 시드 직후라는 이번 테스트 환경 특유의 조건일 가능성이 있다.

---

## 13. 포트폴리오 후보 문장

> slow query log(`long_query_time=0`)와 `EXPLAIN`으로 상품 목록 검색(검증개수 필터 포함) API의 count 쿼리가 동일한 상관 서브쿼리를 행당 두 번 중복 실행하는 것을 확인하고, `CriteriaBuilder.between()`으로 서브쿼리를 하나로 통합해, k6 20VU/60s·5만 건 데이터 환경에서 p95 응답 시간을 7.17s에서 4.03s로 43.8% 개선(p99 7.96s→4.42s, RPS 5.18→8.53 +64.7%). 동일 조건 반복 측정(v1/v2) 모두에서 재현됨.

수치는 실측값이며, 위 "남은 한계"를 함께 명시한다 — 이 문장만으로는 "완전히 해결했다"는 인상을 주지 않도록 포트폴리오 본문에는 반드시 §12 요약(예: "다만 전체 응답 시간은 여전히 개선 여지가 있어 후속 후보로 관리 중")을 함께 적을 것을 권장한다.

---

## 14. 포트폴리오 상세 작성용 자료

### 문제 상황 요약

상품 목록/검색 API(`GET /api/v1/products`)에 완료된 체크리스트 항목 개수 범위 필터(`minVerifiedCount`~`maxVerifiedCount`)를 걸면, Spring Data JPA가 페이지네이션을 위해 자동 생성하는 count 쿼리가 심하게 느려졌다(관측: 3.8~4.3s). 코드를 읽어보니 완료 개수를 세는 상관 서브쿼리 하나를 정의해 두고 `>=`/`<=` 두 비교에 나눠 썼는데, Hibernate가 이를 SQL로 변환하며 동일한 서브쿼리를 두 번 풀어썼다.

### 의사결정 과정

count 쿼리를 아예 없애는 `Slice` 전환이 이론상 더 큰 효과가 있었지만, 프론트엔드가 `totalElements`/`totalPages`로 페이지 번호와 상품 개수를 실제로 표시하고 있어 백엔드 단독 변경으로는 배포할 수 없었다. 키워드 검색에 FULLTEXT 인덱스를 적용하는 방법도 검토했지만 검색 결과 의미가 달라질 위험이 있어 검증 범위가 커졌다. 결국 API 계약을 바꾸지 않고 회귀 위험이 가장 낮은, "중복 서브쿼리를 `BETWEEN`으로 통합"하는 방법을 선택했다.

### 해결

`ProductApplicationService.verifiedCountBetween()`에서 `min`/`max`가 모두 주어졌을 때 `cb.greaterThanOrEqualTo` + `cb.lessThanOrEqualTo` 대신 `cb.between()`을 사용하도록 10줄 미만을 수정했다. 서브쿼리 자체의 조건이나 API 응답은 바꾸지 않았다.

### 결과

같은 조건(20VU, 60s, 5만 건 데이터, ANALYZE 이후 동일 통계 상태)에서 v1/v2 두 차례 재측정한 결과(v2 기준), HTTP p95가 7.17s → 4.03s(-43.8%), p99가 7.96s → 4.42s(-44.5%), DB count 쿼리 p95가 4.37s → 2.71s(-38.0%), RPS가 5.18 → 8.53(+64.7%)로 개선됐다. 다만 여전히 p95 4.03s는 느린 편이며, 근본 구조(상관 서브쿼리가 키워드 필터보다 먼저 전체 후보군에 대해 평가되는 문제)는 남아 있다.

### 핵심 근거

- 관련 코드: `backend/src/main/java/com/c203/limit/domain/product/service/ProductApplicationService.java` (`verifiedCountBetween`)
- 관련 커밋: 없음 (워킹 트리 변경, 미커밋 — 기준 커밋 `05d1657`)
- 관련 테스트: `ProductApplicationServiceTests`, `ProductMockControllerTests` (그린), 실 DB 수동 검증(`totalElements=3489` 일치)
- 관련 k6 스크립트: `evidence/k6-product-list.js` (v2, `p(99)` 포함)
- 관련 시드 스크립트: `evidence/seed.sql`
- 관련 SQL/EXPLAIN: 본문 §4-1, §4-3
- 관련 원본 결과: `evidence/before_summary.json`/`before_v2_summary.json`, `evidence/after_summary.json`/`after_v2_summary.json`, `evidence/baseline_pre_analyze_summary.json`, `evidence/before_count_query_sample.sql`, `evidence/after_count_query_sample.sql`
- 관련 Grafana metric: 없음 (모니터링 스택 미구성, §12)

---

## 다음 성능 개선 후보 3개

1. **상품 목록/검색 API 잔여 병목 — count 쿼리 자체 제거 또는 필터 평가 순서 재구성.** 이번 수정 후에도 p95 4.03s(p99 4.42s)로 여전히 느리다. `Slice` 전환(count 쿼리 제거, 프론트 `totalElements`/`totalPages` 의존 부분 동시 수정 필요) 또는 키워드 필터를 상관 서브쿼리보다 먼저 평가하도록 쿼리를 재구성하는 방법을 다음 후보로 제안한다.
2. **상품 상세 조회 API(`GET /api/v1/products/{productId}`) — 요청당 3~4개 순차 쿼리.** `ProductApplicationService.detail()`에서 체크리스트 집계, `wishlist`/`chat_room` COUNT 서브쿼리(`ProductEngagementReader`), 확정 기능 체크리스트 조회가 순차 실행된다. `wishlist`/`chat_room`에 `listing_id` 인덱스가 있는지, 있다면 순차 실행 자체를 병렬/배치화할 수 있는지 확인이 필요하다(현재는 `가설` 단계, 미측정).
3. **위시리스트 목록(`GET /api/v1/members/me/favorites`) — 대량 관심상품 등록 사용자의 썸네일 서브쿼리 비용.** `ListingImageRepository.findFirstByListingIdsAndImageType`이 `MIN(id) GROUP BY` 서브쿼리로 썸네일을 조회한다. 사용자가 관심상품을 수백 개 이상 등록한 경우의 비용을 실측 필요(현재는 `가설` 단계).

> 노션 "취준/limit 개선사항" 페이지에 토글로 옮겨야 하는데, 이번 세션에서는 Notion 연동이 인증되어 있지 않아 직접 쓰지 못했습니다. 위 3개 항목을 그대로 토글 3개로 붙여넣으시면 됩니다. Notion 연동을 인증해 주시면 다음부터는 제가 직접 쓸 수 있습니다.
