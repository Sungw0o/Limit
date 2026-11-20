# 상품 상세 조회 API — 가설 기각 기록

- 대상 API: `GET /api/v1/products/{productId}` (`ProductApplicationService#findPublicDetail`)
- 작업일: 2026-08-10
- 결론: **가설 기각 — 이번 측정 조건에서는 유의미한 병목 없음. 코드 변경 없음.**

프로젝트 지침("실제 실험 결과를 먼저 얻고, 그중 의미 있는 결과만 포트폴리오 후보로 분류한다")에 따라, 손대지 않았지만 측정한 결과를 그대로 남긴다.

## 가설

앞선 코드 조사(1차 문서, 병목 후보 2위)에서 "요청당 3~4개 순차 쿼리, `wishlist`/`chat_room` 인덱스 미확인"을 가설로 남겼었다.

## 코드 재확인 결과 (측정 전)

- `ListingRepository.findByIdAndStatusAndDeletedAtIsNull`에 이미 `@EntityGraph(attributePaths = {"category", "category.parent"})`가 걸려 있어, listing+category+parent가 **fetch join 1쿼리**로 묶여 있었다. N+1 우려는 애초에 없었다(코드 근거: `ListingRepository.java:30-31`).
- `ProductEngagementReader.findByListingId`는 `wishlist`/`chat_room` COUNT 두 개를 상관 서브쿼리로 **한 SELECT에 묶어** 이미 최적화돼 있었다(코드 주석에 N+1 회피 의도가 명시돼 있음, `ProductEngagementReader.java:15-16`).
- 실제 순차 쿼리는 listing+category+parent(1) + 체크리스트 집계(1) + 썸네일(1) + engagement(1) + 확정기능 조회(1) = **5개**로, 최초 가설(3~4개)보다는 많지만 각각 단순 인덱스 조회다.

## 측정 (재현 환경은 §2 1차 문서와 동일 — 샌드박스 2vCPU/3.8GB, MySQL rootless, 5만 건 listing 시드)

- k6: 20 VU, 60s, `productId`는 1~50000 균등 무작위, think time 200ms
- 실행 시각: 2026-08-10T08:27:39Z ~ 08:28:39Z
- 원본: `evidence/detail_baseline_summary.json`

| Metric | 값 |
|---|---:|
| 요청 수 | 5,634건 |
| RPS | 93.56 req/s |
| avg | 12.62 ms |
| p50 | 6.68 ms |
| p90 | 23.83 ms |
| p95 | 43.98 ms |
| p99 | 104.09 ms |
| max | 276.97 ms |
| Error Rate | 0.00% |
| HikariCP acquire avg | 0.136 ms (1.529s / 11,275건) |
| HikariCP acquire max | 112.97 ms |
| HikariCP pending | 0 (경합 없음) |

slow query log(`long_query_time=0`)를 5,634건 요청 전수에 대해 확인한 결과, **요청당 정확히 5개 쿼리**(가설과 다르지 않은 구조 확인)가 나갔고, 그중 **0.05초를 넘는 쿼리는 단 하나도 없었다.**

## 판단

- p95 44ms, p99 104ms는 사용자 응답 기준으로 충분히 빠르다. HikariCP도 경합 없이(`pending=0`) 여유 있게 처리됐다(pool 10, 20VU에서도 acquire 대기가 사실상 0에 가까움).
- "쿼리가 5개라 순차 실행 오버헤드가 있을 것"이라는 가설 자체는 코드 구조상 사실이지만, **실제 영향은 미미하다는 것이 실측으로 확인됐다** — 5개 쿼리 모두 단일 컬럼 인덱스 조회라 각각 1ms 안팎이고, 합쳐도 네트워크 왕복 포함 두 자릿수 ms 수준이다.
- 이번 데이터 규모(listing 5만 건, 위시리스트/채팅방 규모는 상품 목록 시드에 포함되지 않아 0에 가까움 — §12 한계)와 20VU 조건에서는 손댈 이유가 없다고 판단해 **코드를 변경하지 않았다.**

## 한계 (다음에 재검토할 조건)

- HikariCP `pending=0`은 20VU 기준이다. 더 높은 동시성(예: 100~200VU)에서 5쿼리 구조가 커넥션 점유 시간 누적으로 문제가 될 수 있는지는 미확인이다.

---

## 추가 검증 (2026-08-11): 인기 상품 조건 — 가설 기각 재확인

위 "한계"에서 남겨둔 조건(위시리스트·채팅방이 다수 몰린 인기 상품)을 채워서 재측정했다.

**시드 추가:** buyer 계정 2,000명, listing 3개(`id=1,1000,25000`)에 각각 wishlist ~1,000건 + chat_room ~1,000건 집중(`evidence/seed_wishlist.sql`).

**측정:** k6 20VU/60s, `productId`를 위 3개 인기 상품 중 균등 무작위 선택. 실행 시각 2026-08-11T00:12:15Z~00:13:16Z. 원본: `evidence/detail_hot_summary.json`.

| Metric | 일반 상품(위 본문) | 인기 상품(wishlist/chat 각 ~1,000건) |
|---|---:|---:|
| RPS | 93.56 | 92.78 |
| avg | 12.62 ms | 14.23 ms |
| p95 | 43.98 ms | 48.89 ms |
| p99 | 104.09 ms | 120.76 ms |
| max | 276.97 ms | 257.23 ms |

**결론:** wishlist/chat_room 각각 1,000건 집중에서도 유의미한 저하가 없다(p95 +11%, p99 +16% 정도로 오차 범위에 가깝다). `wishlist.idx_wishlist_listing`, `chat_room.uk_chat_room_listing_users`(listing_id가 선두 컬럼이라 prefix 조회에 그대로 쓰임) 인덱스가 이미 존재해 `COUNT(*) WHERE listing_id=?`가 인덱스 레인지 스캔으로 처리되기 때문으로 추정된다(`가설` — 실행계획을 별도로 뜯어보진 않았음). **가설을 최종 기각한다. 코드 변경 없음.**

## 추가 검증 (2026-08-11): 위시리스트 목록 API (파워유저 조건) — 가설 기각

- 대상: `GET /api/v1/members/me/favorites` (병목 후보 3위, "대량 관심상품 등록 사용자의 썸네일 서브쿼리 비용")
- 시드: 파워유저 5명, 각 1,000개 상품 관심 등록(`evidence/seed_wishlist.sql`)
- 측정: k6 20VU/60s, 5명 중 무작위 토큰으로 `page=0~9, size=20` 무작위 조회(1,000건 중 앞 200건 범위). 인증은 `POST /api/v1/auth/sessions`로 실제 로그인해 발급받은 JWT 사용. 실행 시각 2026-08-11T00:13:16Z~00:14:18Z. 원본: `evidence/favorites_summary.json`.

| Metric | 값 |
|---|---:|
| RPS | 92.28 |
| avg | 12.61 ms |
| p95 | 26.16 ms |
| p99 | 119.13 ms |
| max | 488.19 ms |
| HikariCP pending | 0 (경합 없음, 두 테스트 합산 16,831건 acquire 평균 0.34ms) |

**결론:** 관심상품 1,000개를 등록한 파워유저의 페이지네이션 조회도 p95 26ms로 빠르다. `WishlistRepository`의 `JOIN FETCH` + `ListingImageRepository`의 배치 썸네일 조회(둘 다 이미 N+1을 피하도록 설계돼 있었음, 원 코드 주석 확인)가 이 데이터 규모에서는 충분히 효율적이다. **가설을 기각한다. 코드 변경 없음.**

## 추가 검증 (2026-08-11): 상품 수정 PATCH의 선택 기능 해제 — 가설 기각 (구조는 실재, 영향은 미미)

- 대상: `PATCH /api/v1/products/{productId}` (`confirmedFeatures` 필드로 선택 기능 해제, 병목 후보 4위)
- 코드 근거: `reconcileConfirmedFeatures()` → `isChecklistItemLocked()`가 제거 대상 항목마다 `evidence`, `reinspection_request_item`, `rtc_session_checklist_result`, `media_upload_session`, `inspection_session_test_result` 5개 테이블에 대해 순차 `EXISTS` 조회를 한다. `UpdateProductRequest.confirmedFeatures`에 `@Size(max = 5)` 제약이 있어 **한 요청당 최대 5개 항목 × 5개 테이블 = 25개 조회**로 상한이 있다(코드 확인 후 알게 된 사실 — 애초에 우려했던 "무제한 N+1"은 아니었다).

**측정 방법:** 판매자 계정으로 실제 로그인(JWT) 후, 선택 기능 체크리스트 항목 5개를 등록해 둔 매물에 `confirmedFeatures: []`로 PATCH해 5개를 한 번에 해제시켰다. slow query log(`long_query_time=0`)로 실제 나간 쿼리를 전수 확인했다.

| 항목 | 값 |
|---|---:|
| HTTP 처리 시간(단일 요청) | 314.6 ms (JVM 첫 요청, JIT 미최적화 상태 포함 — 순수 참고용) |
| `isChecklistItemLocked` 관련 EXISTS 쿼리 수 | 정확히 25개 (5항목 × 5테이블, 코드 예측과 일치) |
| 해당 25개 쿼리의 개별 실행 시간 | 79µs ~ 3.18ms (합계 약 10.4ms) |

**판단:** 코드 구조상 "N+1처럼 보이는" 패턴은 실재하지만, (1) `@Size(max=5)`로 요청당 최대 25개로 상한이 걸려 있고, (2) 각 조회가 `listing_checklist_item_id` 단일 컬럼 인덱스 조회라 25개를 다 더해도 약 10ms 수준이며, (3) 이 API는 판매자가 상품을 수정할 때만 호출되는 저빈도 API라 동시성 경합 가능성도 낮다. **가설을 기각한다. 코드 변경 없음.**

**이 실험에서 발견한, 코드가 아닌 테스트 데이터 문제 (기록용):**
- `Listing.sellerId`는 클래스 주석("seller_id/buyer_id는 회원 도메인 참조라 FK 없이 ID만 보관한다")대로 **`user_account.user_id`를 저장**하는 필드였는데, 1차 시드 스크립트(`evidence/seed.sql`)에서는 `seller.seller_id`(별도 PK)를 넣어놨다 — 공개 조회 API만 쓸 때는 소유권 검증이 없어 드러나지 않다가, 이번에 PATCH(소유자 검증 필요)를 처음 테스트하면서 403으로 드러났다. 이번 실험 대상 리스팅 1건만 수정해서 우회했고, 5만 건 전체를 고치진 않았다 — 이후 판매자 인증이 필요한 API를 더 테스트하려면 시드 스크립트의 `seller_id` 채우는 로직 자체를 고쳐야 한다.
- `listing_checklist_item.completion_status`에 존재하지 않는 enum 값 `'IN_PROGRESS'`(실제 유효값은 `PENDING`/`SUBMITTED`/`COMPLETED`뿐)를 시드 스크립트가 넣어놔서, 엔티티를 완전히 읽어들이는 경로(`findByListingIdOrderByDisplayOrderAsc`)에서 500 에러가 났다. 전체 데이터셋에서 `IN_PROGRESS`로 들어간 51,159건을 `SUBMITTED`로 일괄 수정했다. 이 수정은 앞서 보고한 1번 문서(목록/검색 count 쿼리)의 Before/After 수치에는 영향이 없다 — 그 경로는 `completion_status='COMPLETED'` 문자열 비교만 하고 enum으로 역직렬화하지 않기 때문이다(수천 건 요청이 에러 없이 처리된 것으로도 확인됨).

## 종합

1차 코드 조사에서 나온 병목 후보 2~4위(상세조회, 위시리스트 목록, 상품 수정 PATCH의 선택 기능 해제)를 모두 실측했고, 이번 데이터 규모(listing 5만, 인기 상품당 wishlist/chat 1,000건, 파워유저당 관심상품 1,000건, PATCH는 상한 25쿼리)와 20VU 조건에서는 **셋 다 손볼 근거가 없었다.** 이미 배치 쿼리·적절한 인덱스·요청 크기 상한으로 설계돼 있었다는 것이 실측으로 확인됐다 — "코드 냄새"가 곧 "실측 병목"은 아니라는 걸 보여주는 사례로 남긴다. 실제로 손볼 근거가 있었던 건 1번 문서(목록/검색 count 쿼리 중복 서브쿼리)뿐이었다.

