# 진단 요약 조회 API — 항목×필드 N+1을 매물 단위 배치 조회로 개선

- 대상 API: `GET /api/v1/inspections/products/{productId}/diagnosis-summary` (`ProductDiagnosisSummaryService#getSummary`)
- 작업일: 2026-08-11
- 기준 커밋: `05d1657` (dev, 성능 분석 하네스와 스킬 추가) 이후 워킹 트리 변경, **미커밋**
- 변경 파일:
  - `backend/src/main/java/com/c203/limit/domain/inspection/service/DiagnosisAggregationService.java` (배치 조회 메서드 `getFieldValuesForListing` 추가 — 기존 `getFieldValue`/`getDiagnosis`는 시그니처·동작 변경 없음)
  - `backend/src/main/java/com/c203/limit/domain/inspection/service/ProductDiagnosisSummaryService.java` (요약 조립 로직을 배치 메서드 호출로 교체)
  - 테스트: `DiagnosisAggregationServiceTests.java`, `ProductDiagnosisSummaryServiceTests.java` (배치 계약에 맞춰 갱신 + 배치 전용 회귀 테스트 4건 추가)

---

## 0. 요약 (TL;DR)

체크리스트 항목이 여러 개인 매물의 진단 요약 조회가, 항목마다·필드마다(14개 필드) `DiagnosisAggregationService#getFieldValue`를 반복 호출하며 evidence/OCR/DXDIAG/배터리 리포트 테이블을 매번 다시 조회하는 구조였다. 같은 매물(listing id=5, 체크리스트 항목 4개, evidence 0건) 단건 요청 기준 실제 쿼리 수가 **148개**였다(slow query log 전수 확인). 매물 단위로 evidence를 1번, OCR/DXDIAG/배터리 결과를 각 1번(최대 4쿼리)만 조회하고 필드 선택 로직은 그대로 재사용하는 배치 메서드(`getFieldValuesForListing`)를 추가해, 동일 요청의 쿼리 수를 **8개로 94.6% 감소**시켰다. 같은 조건(k6 20VU/60s, 5만 건 시드)에서 HTTP p95는 864.25ms → 36.91ms(**-95.7%**), p99는 1.46s → 61.78ms(**-95.8%**), RPS는 30.48 → 91.57(**+200.4%**)로 개선됐다. `getFieldValue`/`getDiagnosis`는 다른 프로덕션 호출자(`DiagnosisValueConfirmationService`, `DeviceInfoCompletionService`)가 있어 그대로 두고, 배치 메서드는 추가 전용으로 구현했다.

---

## 1. 문제 상황

`ProductDiagnosisSummaryService.buildSummary()`는 매물의 체크리스트 항목 전체(`checklistItems`)를 가져온 뒤, `DiagnosisFieldName.values()`(14개 필드) 각각에 대해 `bestSummaryItem()`을 호출한다. `bestSummaryItem()`은 항목마다 `toSummaryItem(item.getId(), fieldName)`을 호출하고, 이 메서드가 `DiagnosisAggregationService.getFieldValue(itemId, fieldName)`을 호출한다.

`getFieldValue()`는 호출될 때마다:
1. `listingChecklistItemRepository.findById(itemId)` — 항목 재조회
2. `collectOcrValues(item)` — `evidenceRepository.findAllByListingChecklistItem_Id(itemId)`로 PHOTO 증거 조회 + (있으면) `ocrResultRepository.findAllByEvidenceIdIn(...)`
3. `collectFileParseValues(item)` — 진단파일 증거 조회(`evidenceRepository.findAllByListingChecklistItem_Id` 또는 기기정보 항목이면 `findAllByListingId`) + (있으면) `dxdiagResultRepository`/`batteryReportResultRepository` 조회
4. 위에서 값을 못 찾으면 `fallbackEditTarget(itemId)` — `findById` 재조회 + evidence 재조회

를 **매번 새로 실행**한다. 즉 항목 수 N, 필드 수 M(=14)이면 최악의 경우 요청 하나당 O(N×M) 쿼리가 나간다. `resolveOriginalFileUrl()`도 필드마다 `evidenceRepository.findById(sourceEvidenceId)`를 별도 호출해 여기에 더해진다.

이 API는 `GET /api/v1/inspections/products/{productId}/diagnosis-summary`로 **인증 없이 누구나 호출 가능한 공개 조회**라 트래픽에 그대로 노출된다.

코드 조사만으로는 실제 영향도를 확정할 수 없어 처음엔 `가설`로 분류했고(서브에이전트 조사 결과: 타 도메인 병목 후보 1위), 아래에서 실측했다.

---

## 2. 재현 환경

Docker를 사용할 수 없는 격리 샌드박스(비루트, privileged 불가)였기 때문에 아래와 같이 대체 구성했다. **운영 환경과 스펙이 다르므로 절대값이 아니라 Before/After 상대 비교로만 사용한다.** 이전 후보(§ `2026-08-10-product-list-verified-count-subquery.md`)와 동일한 환경이다.

| 항목 | 값 |
|---|---|
| 실행 환경 | 격리 리눅스 샌드박스 (Docker 미사용, rootless) |
| CPU | 2 vCPU |
| Memory | 3.8 GB (전체, MySQL+App+k6 공유) |
| Java | Temurin 21.0.12 |
| Spring Boot | 4.0.7 |
| DB | MySQL 8.0.39 Community, 제네릭 tarball, rootless 실행 (포트 3307) |
| InnoDB buffer pool | 768MB |
| 애플리케이션 인스턴스 수 | 1 (java -jar, 기본 JVM 옵션) |
| MongoDB / Redis | 미기동. 진단 요약 경로는 JPA만 사용 확인. 앱은 연결 실패 경고 로그만 남기고 정상 기동 |
| Connection Pool | HikariCP 기본값, `maximumPoolSize=10` |
| 테스트 데이터 규모 | `listing` 50,000행, `listing_checklist_item` 255,806행, `evidence` **0행**(이번 시드에는 증거 업로드 데이터가 없음 — §12 한계) |
| 대상 listing (단건 쿼리 수 검증) | id=5, 체크리스트 항목 4개, evidence 0건 |
| k6 버전 | v0.54.0 |
| k6 VU | 20 (constant-vus) |
| k6 duration | 60s |
| think time | 200ms/iteration |
| 테스트 endpoint | `GET /api/v1/inspections/products/{id}/diagnosis-summary`, `id`는 1~50000 균등 무작위 (스크립트: `evidence/k6-diagnosis-summary.js`) |
| 기타 | slow_query_log 전체 활성화(`long_query_time=0`)로 모든 쿼리 기록 |
| Before/After 코드 분리 | 같은 워킹 트리에서 `git show HEAD:...`로 수정 전 원본 두 파일만 되돌린 별도 빌드(`backend_before`)로 Before를 측정하고, 같은 세션에서 곧바로 수정본을 재빌드해 After를 측정했다 — 동일 MySQL 데이터, 동일 머신, 동일 세션에서 앞뒤로 측정 |

---

## 3. Baseline (Before, 원본 코드)

실행 시각(UTC): 2026-08-11T00:55:37Z ~ 00:56:38Z. 원본: `evidence/diagsummary_before_summary.json`.

### 단건 요청 쿼리 수 (listing id=5, 체크리스트 항목 4개, evidence 0건)

| 항목 | 값 |
|---|---:|
| 요청당 쿼리 수 (slow query log 전수) | **148개** |
| 응답 시간 (JVM 워밍업 후 단건) | 661.5 ms |

### k6 부하 테스트 (20VU/60s)

| Metric | 값 |
|---|---:|
| 요청 수 | 1,846건 |
| RPS | 30.48 req/s |
| avg | 452.64 ms |
| p50(med) | 400.43 ms |
| p90 | 757.50 ms |
| p95 | 864.25 ms |
| p99 | 1.46 s |
| max | 2.54 s |
| Error rate | 0.00% |
| HikariCP acquire avg | 124.76 ms (230.779s / 1,850건, 테스트 전/후 누적값 차분) |
| HikariCP acquire max | 1.522 s (테스트 종료 시점 누적 max) |
| HikariCP active/idle/pending (테스트 종료 후 스냅샷) | 0 / 10 / 0 |
| JVM Threads live | 36(테스트 전) → 47(테스트 후) |
| HikariCP pool size | 10 (기본값) |

---

## 4. 원인 분석

### 4-1. 항목×필드 반복 조회 (코드 구조 — 확정)

§1에서 설명한 대로 `getFieldValue(itemId, fieldName)`이 항목 4개 × 필드 14개 = 56회 호출됐다. 호출마다 `findById` 1회, evidence 조회 1~2회(항목/매물 단위), 값이 없으면 `fallbackEditTarget`에서 `findById` + evidence 조회가 추가된다 — 이번 시드는 evidence가 0건이라 OCR/DXDIAG/배터리 결과 테이블 조회 자체는 스킵되지만(빈 id 리스트로 조회 자체를 안 함), evidence 유무를 판별하기 위한 `findAllByListingChecklistItem_Id`/`findAllByListingId` 조회와 `findById` 재조회는 필드마다 반복된다. 실측 148개는 이 반복 구조가 실제 SQL 실행 횟수로 이어진다는 근거다.

### 4-2. HikariCP 커넥션 풀 대기 (증상)

`hikaricp_connections_acquire_seconds` 평균이 124.76ms, 최대 1.522s로 나타났다 — 20VU가 `maximumPoolSize=10`을 두고 경합한 결과다. 요청 하나가 148개의 짧은 쿼리를 순차 실행하는 동안 커넥션을 길게 점유하기 때문에, 동시 요청이 늘수록 대기가 누적된다. 이는 §4-1의 결과이지 풀 크기 자체의 결함은 아니다.

### 4-3. evidence 0건 조건의 해석

이번 시드 데이터에는 증거(사진/진단파일) 업로드가 전혀 없어 OCR/DXDIAG/배터리 파싱 결과 테이블 조회는 실제로 발생하지 않았다. 즉 148개 쿼리는 "값을 찾는 비용"이 아니라 **"항목·필드 조합마다 evidence 존재 여부를 반복 확인하는 비용"**이다. evidence가 있는 매물이라면 OCR/DXDIAG/배터리 조회가 추가로 붙어 쿼리 수가 더 늘어날 것으로 예상되지만(`가설` — evidence가 있는 매물로는 별도 측정하지 않음), 이번 조건(0건)은 오히려 구조적 하한선에 가까운 관찰이라고 판단한다.

---

## 5. 검토한 대안

| 대안 | 기대 성능 | 구현 복잡도 | 정합성 영향 | 부작용/운영 위험 | 비고 |
|---|---|---|---|---|---|
| **A. 매물 단위 배치 조회 메서드 추가 (채택)** | evidence 1쿼리 + OCR/DXDIAG/배터리 각 1쿼리(최대 4쿼리)로 항목·필드 수와 무관하게 고정 | 중간 (기존 필드 선택 로직을 데이터 소스만 바꿔 재사용하는 별도 메서드 4개 추가, 약 150줄) | 없음 (필드 선택 로직 `isFieldVisibleFor`/`putDxdiagValue`/우선순위 규칙을 그대로 재사용 — 회귀 테스트로 동등성 확인) | `getFieldValue`가 다른 호출자(`DiagnosisValueConfirmationService`, `DeviceInfoCompletionService`)에서도 쓰이므로 **건드리지 않고 추가만** 해야 함 — 실수로 시그니처/동작을 바꾸면 그쪽이 회귀 위험 | 매물 하나에 항목이 아주 많아지면 evidence 리스트를 메모리에 다 올려야 하지만, 애초에 요약 API가 매물 하나 단위라 규모가 제한적 |
| B. 필드별 벌크 쿼리 (`IN (itemId1, itemId2, ...)`로 항목을 한 번에) | A와 유사한 효과 | A보다 큼 — evidence/OCR/DXDIAG/배터리 4개 리포지토리 메서드에 `findAllByListingChecklistItem_IdIn` 류 신규 메서드 추가 필요, 결과를 itemId별로 다시 그룹핑하는 로직도 필요 | 없음 | 신규 리포지토리 메서드가 늘어 유지보수 표면이 커짐 | A와 최종 도달하는 쿼리 수는 비슷한데, A는 이미 있는 `findAllByListingId`(매물 단위) 하나로 항목 구분 없이 한 번에 가져올 수 있어 신규 리포지토리 메서드가 필요 없었음 |
| C. `getFieldValue` 자체에 캐시(예: 요청 스코프 캐시) 적용 | 같은 항목 재조회는 줄지만 항목×필드 반복 호출 구조 자체는 안 바뀜 | 낮음 | 캐시 무효화 로직이 없으면 트랜잭션 내에서도 오래된 값 반환 위험 | `getFieldValue`가 조회 전용 유스케이스이면서 다른 도메인(확정값 반영 등)에서도 호출돼 캐시 범위를 잘못 잡으면 다른 기능에 영향 | 근본적으로 N+1을 없애는 게 아니라 완화하는 수준이라 제외 |

---

## 6. 의사결정

**A(매물 단위 배치 조회 메서드 추가)를 선택했다.**

- B(벌크 IN 쿼리)도 항목 수만큼 반복하지 않는다는 점은 같지만, 이미 `EvidenceRepository.findAllByListingId(listingId)`가 존재해 매물 단위로 증거 전체를 한 번에 가져올 수 있었다 — 항목별로 IN절을 만드는 신규 리포지토리 메서드를 추가할 필요가 없어 A가 변경 범위가 더 작다.
- C(캐시)는 항목×필드 반복 호출 자체를 없애지 못하고, `getFieldValue`의 다른 호출자(판매자가 값을 확정하는 흐름 등)에서 캐시 무효화 시점을 잘못 잡으면 최신 값이 아닌 결과를 반환할 위험이 있어 제외했다.
- 가장 중요한 제약: `getFieldValue`/`getDiagnosis`는 `DiagnosisValueConfirmationService`, `DeviceInfoCompletionService`(및 각각의 테스트)에서 이미 쓰고 있다. 이번 문제는 "항목 하나를 조회하는 API"가 아니라 "매물 전체 요약을 한 번에 봐야 하는 API"에서만 발생하므로, 기존 단건 조회 경로는 그대로 두고 **매물 단위 배치 조회를 완전히 새 메서드로 추가**하는 것이 가장 안전하다고 판단했다.

---

## 7. 구현

**변경 파일 1: `DiagnosisAggregationService.java`**

`getFieldValuesForListing(Long listingId, List<ListingChecklistItem> items)`를 추가했다. 매물 전체 evidence를 `evidenceRepository.findAllByListingId(listingId)` 1회로 가져와 항목 id별로 메모리에서 그룹핑하고, PHOTO/DIAGNOSTIC_FILE evidence id 목록을 매물 단위로 모아 `ocrResultRepository`/`dxdiagResultRepository`/`batteryReportResultRepository`를 각 1회(최대 3회)만 호출한다. 필드 선택 로직(`isFieldVisibleFor`, `putDxdiagValue`, 기기정보 항목 판별, 우선순위 규칙)은 기존 `collectOcrValues`/`collectFileParseValues`/`fallbackEditTarget`와 **동일한 로직을 데이터 소스만 배치 맵으로 바꿔** 재사용했다(`collectOcrValuesFromBatch`, `collectFileParseValuesFromBatch`, `fallbackEditTargetFromBatch`) — 결과가 갈리지 않도록 하기 위함이다. evidence id별 CDN URL도 같은 배치에서 맵으로 함께 반환해, 요약 조립 쪽의 `evidenceRepository.findById` 반복 호출도 없앴다.

```java
@Transactional(readOnly = true)
public ListingDiagnosisBatch getFieldValuesForListing(Long listingId, List<ListingChecklistItem> items) {
    List<Evidence> allEvidence = evidenceRepository.findAllByListingId(listingId);
    Map<Long, List<Evidence>> evidenceByItem =
            allEvidence.stream().collect(Collectors.groupingBy(e -> e.getListingChecklistItem().getId()));
    // photoEvidenceIds / diagnosticFileEvidenceIds를 매물 단위로 모아
    // ocrResultRepository / dxdiagResultRepository / batteryReportResultRepository를 각 1회만 호출
    // (항목별로 in-memory 필터링 — 기존 collectOcrValues/collectFileParseValues와 동일 로직 재사용)
    ...
}
```

`getFieldValue()`/`getDiagnosis()`와 그 본문(단건 조회용 `collectOcrValues`/`collectFileParseValues`/`fallbackEditTarget`)은 **한 줄도 바꾸지 않았다** — `DiagnosisValueConfirmationService`, `DeviceInfoCompletionService`가 계속 그대로 쓴다.

**변경 파일 2: `ProductDiagnosisSummaryService.java`**

`buildSummary()`가 체크리스트 항목이 있으면 `getFieldValuesForListing()`을 한 번 호출해 배치 결과를 받고, `bestSummaryItem`/`toSummaryItem`이 항목×필드마다 리포지토리를 호출하는 대신 이 배치 결과(맵 조회)에서 값을 꺼내도록 바꿨다. 더 이상 `EvidenceRepository`를 직접 쓰지 않아 생성자에서 제거했다.

**테스트:**

```
./gradlew test --tests "com.c203.limit.domain.inspection.service.DiagnosisAggregationServiceTests" \
               --tests "com.c203.limit.domain.inspection.service.ProductDiagnosisSummaryServiceTests" \
               --tests "com.c203.limit.domain.inspection.service.DiagnosisValueConfirmationServiceTests" \
               --tests "com.c203.limit.domain.inspection.service.DeviceInfoCompletionServiceTests" \
               --tests "com.c203.limit.domain.inspection.controller.InspectionProductDiagnosisSummaryControllerTests"
BUILD SUCCESSFUL (42 tests)
```

전체 `inspection` 도메인 테스트(371 케이스)도 회귀 없이 그린임을 확인했다.

`DiagnosisAggregationServiceTests`에는 배치 메서드 전용 테스트 4건을 추가했다 — 단건 경로(`getDiagnosis`)와 같은 입력으로 OCR/파일파싱 충돌 판정이 같은 결과를 내는지, 기기정보 항목(`LAP-SCR-013`)이 매물 전체 진단파일 증거를 보는 단건 경로의 특이 동작을 배치 경로도 그대로 재현하는지, evidence는 있지만 파싱 결과가 없을 때 최신 evidence를 교정 대상으로 잡는 fallback 동작이 같은지, CDN URL 맵이 올바르게 채워지는지를 검증한다. 이 중 하나(`batchExposesCdnUrlPerEvidenceId`)를 작성하는 과정에서 `Collectors.toMap(Evidence::getId, Evidence::getCdnUrl)`이 `cdnUrl`이 아직 null인 evidence(업로드는 됐지만 아직 처리 전)에서 `NullPointerException`을 던지는 실제 버그를 발견해 수동 `HashMap` 채우기로 고쳤다 — 회귀 테스트가 구현 결함을 실제로 잡아낸 사례라 기록해 둔다.

**k6 스크립트:** `evidence/k6-diagnosis-summary.js` (Before/After 동일 스크립트, VU/duration 고정)
**시드 스크립트:** `evidence/seed.sql`

---

## 8. 검증

Before와 동일한 조건(같은 MySQL 데이터, 같은 세션 내에서 코드만 원본↔수정본으로 교체한 새 애플리케이션 프로세스, 같은 k6 스크립트/VU/duration)에서 재측정했다.

실행 시각(UTC): 2026-08-11T00:49:54Z ~ 00:50:54Z. 원본: `evidence/diagsummary_after_summary.json`.

### 단건 요청 쿼리 수 (listing id=5, 동일 조건)

| 항목 | Before | After | Change |
|---|---:|---:|---:|
| 요청당 쿼리 수 | 148개 | **8개** | **-94.6%** |
| 응답 시간 (단건) | 661.5 ms | 236.4 ms | -64.3% |

### k6 부하 테스트 (20VU/60s)

| Metric | 값 |
|---|---:|
| 요청 수 | 5,513건 |
| RPS | 91.57 req/s |
| avg | 16.93 ms |
| p50(med) | 12.37 ms |
| p90 | 29.92 ms |
| p95 | 36.91 ms |
| p99 | 61.78 ms |
| max | 339.62 ms |
| Error rate | 0.00% |
| HikariCP acquire avg | 0.549 ms (3.028s / 5,517건, 테스트 전/후 누적값 차분) |
| HikariCP acquire max | 0.177 s (테스트 종료 시점 누적 max) |
| HikariCP active/idle/pending (테스트 종료 후 스냅샷) | 0 / 10 / 0 |
| JVM Threads live | 36(테스트 전) → 46(테스트 후) |
| HikariCP pool size | 10 (미변경) |

기능 회귀는 §7에서 단위 테스트(42건 타겟 + inspection 도메인 371건 전체)로 확인했고, 실제 HTTP 응답(`{"productId":5,"items":[...]}`)도 Before/After 모두 evidence 0건 조건에서 전 필드 `EXTRACTION_FAILED`로 동일함을 수동 확인했다(값 자체가 바뀌지 않았다는 근거).

---

## 9. Before / After

### HTTP 레벨 (`GET /api/v1/inspections/products/{id}/diagnosis-summary`, k6, 20VU/60s)

| Metric | Before | After | Change |
|---|---:|---:|---:|
| avg | 452.64 ms | 16.93 ms | **-96.3%** |
| p50 | 400.43 ms | 12.37 ms | **-96.9%** |
| p90 | 757.50 ms | 29.92 ms | **-96.0%** |
| p95 | 864.25 ms | 36.91 ms | **-95.7%** |
| p99 | 1.46 s | 61.78 ms | **-95.8%** |
| max | 2.54 s | 339.62 ms | -86.6% |
| RPS | 30.48 | 91.57 | **+200.4%** |
| Error Rate | 0.00% | 0.00% | - |
| 완료 요청 수 (60s) | 1,846 | 5,513 | +198.6% |

### DB 레벨 (단건 요청 쿼리 수, listing id=5, evidence 0건)

| Metric | Before | After | Change |
|---|---:|---:|---:|
| 요청당 쿼리 수 | 148개 | 8개 | **-94.6%** |

### 애플리케이션 레벨

| Metric | Before | After | Change |
|---|---:|---:|---:|
| HikariCP acquire avg | 124.76 ms | 0.549 ms | **-99.6%** |
| HikariCP acquire max | 1.522 s | 0.177 s | -88.4% |
| HikariCP active/idle/pending (테스트 종료 후 스냅샷) | 0 / 10 / 0 | 0 / 10 / 0 | 변화 없음 — 부하 종료 후 값이라 부하 중 포화 여부는 이 지표로 못 봄(§12) |
| HikariCP pool size | 10 (미변경) | 10 (미변경) | - |
| JVM Threads live (테스트 후) | 47 | 46 | 유의미한 차이 없음 |
| CPU / Memory / JVM Heap / GC | N/A (시계열 모니터링 미구성) | N/A | 측정 안 함 |

---

## 10. 결과 해석

이번 개선은 "느린 쿼리를 빠른 쿼리로 바꾼 것"이 아니라 **"항목 수 × 필드 수(14)에 비례해 반복되던 쿼리 실행 횟수를, 매물 하나당 고정된 쿼리 수(최대 5개 안팎)로 바꾼 것"**이다. listing id=5(항목 4개) 기준 148개 → 8개(-94.6%)는 이 구조 변화를 그대로 보여준다.

HTTP 레벨 개선폭(p95 -95.7%)이 DB 레벨 개선폭(쿼리 수 -94.6%)과 비슷한 크기로 나타난 것은, §4-2에서 확인한 HikariCP 커넥션 점유 시간이 함께 줄어든 결과로 해석한다(`가설`: 정확한 인과 기여도는 분리하지 않았음) — 요청 하나가 148개의 순차 쿼리로 커넥션을 오래 붙잡던 것이 8개로 줄면서, 20VU 동시 요청에서의 커넥션 획득 대기(acquire avg 124.76ms → 0.549ms, -99.6%)가 거의 사라졌다. 쿼리 수 감소보다 acquire 개선폭이 더 크게 나타난 것은, 쿼리 수가 줄면서 각 요청의 총 처리 시간(=커넥션 점유 시간)이 줄어 20VU가 10개 커넥션을 두고 벌이던 경합 자체가 완화된 승수 효과로 추정한다.

---

## 11. Trade-off

- `getFieldValuesForListing()`은 매물 하나의 evidence 전체를 메모리에 올린다. 이번 API가 애초에 "매물 하나의 요약"을 반환하는 용도라 항목·evidence 규모가 제한적이라 문제되지 않을 것으로 판단하지만, 한 매물에 evidence가 극단적으로 많이 쌓이는 경우(예: 반려/재검수 반복으로 같은 항목에 evidence가 계속 추가되는 경우)의 메모리 비용은 이번에 측정하지 않았다(§12).
- 필드 선택 로직을 두 벌(단건용 `collectOcrValues`/`collectFileParseValues`, 배치용 `collectOcrValuesFromBatch`/`collectFileParseValuesFromBatch`)로 유지하게 됐다 — 로직이 갈리면 두 경로의 결과가 어긋날 수 있어, 이번엔 회귀 테스트(§7)로 두 경로가 같은 입력에 같은 결과를 내는지 확인해 뒀지만, 앞으로 필드 규칙이 바뀔 때 두 곳을 함께 고쳐야 하는 유지보수 비용이 생겼다.
- `getFieldValue`/`getDiagnosis`(단건 경로)는 그대로 남아 있어, 코드베이스에 "항목 하나 조회용"과 "매물 전체 배치용" 두 가지 진입점이 공존한다 — 의도된 트레이드오프(다른 호출자를 건드리지 않기 위함, §6)이지만 신규 합류자에게는 왜 두 경로가 있는지 설명이 필요하다.

---

## 12. 남은 한계

- 이번 시드 데이터는 evidence가 **0건**이다 — OCR/DXDIAG/배터리 파싱 결과 테이블에 실제 데이터가 있는 매물(즉 필드 값이 실제로 채워지는 경우)에서의 쿼리 수·응답시간 개선폭은 측정하지 못했다(`가설`: evidence가 있으면 OCR/DXDIAG/배터리 조회가 추가되지만, 이 역시 "항목별 반복"에서 "매물 단위 1회"로 바뀌는 구조는 동일하므로 개선 방향 자체는 유지될 것으로 예상하나 수치는 다를 것).
- 단일 샌드박스 환경(2 vCPU, 3.8GB, Docker 미사용, MySQL+App+k6 동일 머신)에서만 측정했다 — 운영 인프라와 조건이 다르다.
- CPU/Memory/JVM Heap/GC/DB CPU는 측정하지 못했다(N/A) — 시계열 모니터링 미구성.
- HikariCP `active`/`idle`/`pending`은 부하 테스트가 끝난 뒤 스크레이프한 스냅샷이라 Before/After 모두 `0/10/0`으로 동일하게 나온다 — 부하 중 실제 포화 여부는 이 지표로 보여주지 못한다. 누적 지표인 `acquire_seconds`(합계·최댓값, 테스트 전/후 차분)는 유효한 근거로 썼다.
- 이번 측정은 v1(단일 실행)만 수행했다 — 앞선 후보(count 쿼리 중복 서브쿼리 개선)처럼 동일 조건 반복 측정(v1/v2)으로 변동 폭을 확인하지는 않았다. 개선폭이 워낙 커서(-95%대) 측정 노이즈로 설명되긴 어렵다고 판단하지만, 엄밀히는 단일 실행 결과라는 한계가 있다.
- listing id=5(항목 4개) 단건으로만 쿼리 수를 확인했다 — 항목 수가 더 많은 매물(예: 카테고리별로 체크리스트 항목이 10개 이상인 경우)에서 Before의 쿼리 수가 선형으로 더 커지는지, After가 여전히 고정 비용에 가까운지는 별도 표본으로 확인하지 않았다(`가설`: 코드 구조상 After는 항목 수와 무관하게 evidence/OCR/DXDIAG/배터리 각 1쿼리로 고정이어야 하지만 실측하지 않음).
- 실제 운영 트래픽 패턴과 다른 합성 데이터·합성 부하 패턴이다.
- Redis/MongoDB를 기동하지 않고 측정했다 — 코드 검색으로 이 경로가 둘 다 쓰지 않음을 확인했지만, 연결 재시도 로그 자체의 미세한 오버헤드 가능성은 배제하지 않았다(`가설`).

---

## 13. 포트폴리오 후보 문장

> 매물 진단 요약 API가 체크리스트 항목×필드(14개) 조합마다 evidence/OCR/DXDIAG/배터리 테이블을 반복 조회하는 것을 slow query log로 확인(단건 요청 148쿼리)하고, 매물 단위로 evidence·파싱 결과를 한 번씩만 배치 조회하도록 리팩터링해 같은 요청의 쿼리 수를 8개로 94.6% 감소시켰다. k6 20VU/60s·5만 건 데이터 환경에서 HTTP p95 응답 시간을 864ms에서 37ms로 95.7% 개선(p99 1.46s→62ms, RPS 30.5→91.6 +200%). 다른 프로덕션 호출자가 있는 기존 단건 조회 메서드는 시그니처·동작을 바꾸지 않고 배치 메서드를 추가하는 방식으로 회귀 위험을 최소화했다.

수치는 실측값이며, 위 "남은 한계"(evidence 0건 조건, 단일 실행, 항목 수가 다른 매물 미측정)를 포트폴리오 본문에 함께 적을 것을 권장한다.

---

## 14. 포트폴리오 상세 작성용 자료

### 문제 상황 요약

매물 상세에서 구매자가 보는 진단 요약 API(`GET /api/v1/inspections/products/{id}/diagnosis-summary`, 인증 불필요 공개 API)가, 체크리스트 항목 수 × 필드 수(14개)에 비례해 evidence/OCR/DXDIAG/배터리 리포트 테이블을 반복 조회하고 있었다. 항목 4개짜리 매물 기준 단건 요청에 148개의 SQL이 나갔다.

### 의사결정 과정

항목별로 `IN` 절을 만들어 벌크 조회하는 방법도 검토했지만, 이미 존재하는 "매물 단위로 evidence 전체를 가져오는" 리포지토리 메서드(`findAllByListingId`)를 그대로 활용하면 신규 리포지토리 메서드 없이 매물 단위 배치 조회가 가능해 변경 범위가 더 작았다. `getFieldValue`에 캐시를 씌우는 방법도 검토했지만 다른 도메인(판매자가 값을 확정하는 흐름)에서도 같은 메서드를 호출하고 있어 캐시 무효화 위험이 있어 제외했다. 가장 중요한 제약은 `getFieldValue`/`getDiagnosis`가 이미 다른 프로덕션 서비스 2곳에서 쓰이고 있다는 것이었고, 그래서 기존 메서드는 건드리지 않고 매물 단위 배치 메서드를 완전히 새로 추가하는 방식을 선택했다.

### 해결

`DiagnosisAggregationService`에 `getFieldValuesForListing()`을 추가해 매물 하나의 evidence/OCR/DXDIAG/배터리 데이터를 각각 1회씩만 조회하고, 기존 필드 선택 로직(우선순위, 기기정보 항목 특수 처리 등)은 데이터 소스만 배치 맵으로 바꿔 그대로 재사용했다. `ProductDiagnosisSummaryService`가 항목×필드마다 리포지토리를 호출하는 대신 이 배치 결과에서 값을 꺼내도록 바꿨다. 기존 단건 조회 메서드(`getFieldValue`, `getDiagnosis`)와 그 호출자는 전혀 수정하지 않았다.

### 결과

같은 조건(20VU, 60s, 5만 건 데이터, 같은 세션 내 원본↔수정본 앞뒤 재측정)에서 HTTP p95가 864ms → 37ms(-95.7%), p99가 1.46s → 62ms(-95.8%), RPS가 30.5 → 91.6(+200.4%)로 개선됐다. 단건 요청 쿼리 수는 148개 → 8개(-94.6%)로 줄었다. 회귀 테스트(42건 타겟 + inspection 도메인 371건 전체)는 모두 통과했고, 회귀 테스트 작성 과정에서 배치 로직의 실제 NPE 버그(`Collectors.toMap`의 null value 처리)도 발견해 수정했다.

### 핵심 근거

- 관련 코드: `backend/src/main/java/com/c203/limit/domain/inspection/service/DiagnosisAggregationService.java` (`getFieldValuesForListing` 및 배치 헬퍼 메서드), `backend/src/main/java/com/c203/limit/domain/inspection/service/ProductDiagnosisSummaryService.java`
- 관련 커밋: 없음 (워킹 트리 변경, 미커밋 — 기준 커밋 `05d1657`)
- 관련 테스트: `DiagnosisAggregationServiceTests`(배치 전용 4건 포함 21건), `ProductDiagnosisSummaryServiceTests`(3건), `DiagnosisValueConfirmationServiceTests`, `DeviceInfoCompletionServiceTests`, `InspectionProductDiagnosisSummaryControllerTests` — 모두 그린, inspection 도메인 전체 371건도 그린
- 관련 k6 스크립트: `evidence/k6-diagnosis-summary.js`
- 관련 시드 스크립트: `evidence/seed.sql`
- 관련 원본 결과: `evidence/diagsummary_before_summary.json`, `evidence/diagsummary_after_summary.json`, `evidence/diagsummary_before_hikari_before.txt`, `evidence/diagsummary_before_hikari_after.txt`, `evidence/diagsummary_after_hikari_before.txt`, `evidence/diagsummary_after_hikari_after.txt`, `evidence/diagsummary_before_run_timestamps.txt`, `evidence/diagsummary_after_run_timestamps.txt`
- 관련 Grafana metric: 없음 (모니터링 스택 미구성, §12)

---

## 다음 성능 개선 후보

1. **evidence가 실제로 존재하는 매물에서의 재측정.** 이번 시드는 evidence 0건이라 OCR/DXDIAG/배터리 파싱 결과 조회가 실제로는 일어나지 않았다. evidence가 채워진 매물로 시드를 보강해 개선폭이 유지되는지 확인이 필요하다(§12).
2. **항목 수가 많은 매물(카테고리별 체크리스트 10개 이상)에서의 재측정.** After가 항목 수와 무관하게 고정 쿼리 수를 유지하는지 실측 확인이 필요하다(§12, 현재는 코드 구조상 `가설`).
3. **다른 도메인 후보 계속 조사.** 서브에이전트 조사에서 나왔던 채팅 미확인 메시지 수 N+1, 결제 스케줄러의 Toss 순차 호출, RTC 닉네임 N+1, 미페이지네이션 주문 이력, 채팅 비관적 락, 재검수 요청 N+1 등은 아직 실측하지 않았다(`가설` 단계).

> 노션 "취준/limit 개선사항" 페이지에 토글로 옮겨야 하는데, 이번 세션에서도 Notion 연동이 인증되어 있지 않아 직접 쓰지 못했습니다. 위 항목들을 그대로 토글로 붙여넣으시면 됩니다. Notion 연동을 인증해 주시면 다음부터는 제가 직접 쓸 수 있습니다.
