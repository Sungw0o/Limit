# 채팅방 목록 API — 방마다 반복되던 미확인 개수 조회를 페이지 단위 배치로 개선

- 대상 API: `GET /api/v1/chat-rooms` (`ChatRoomService#findRooms`)
- 작업일: 2026-08-11
- 기준 커밋: `05d1657` (dev, 성능 분석 하네스와 스킬 추가) 이후 워킹 트리 변경, **미커밋**
- 변경 파일:
  - `backend/src/main/java/com/c203/limit/domain/chat/repository/ChatMessageRepository.java` (배치 조회 `findCounterpartMessagesSince` 추가 — 기존 `countUnreadFromCounterpart`는 그대로 유지)
  - `backend/src/main/java/com/c203/limit/domain/chat/repository/UnreadMessageProjection.java` (신규)
  - `backend/src/main/java/com/c203/limit/domain/chat/service/ChatRoomService.java` (`findRooms`/`toSummary`가 배치 결과를 쓰도록 변경)
  - 테스트: `ChatRoomServiceTests.java` (기존 2건 갱신 + 배치 단일 호출을 검증하는 회귀 테스트 1건 추가)

---

## 0. 요약 (TL;DR)

채팅방 목록 조회가 페이지에 담긴 방(최대 20개, 기본 페이지 크기)마다 `countUnreadFromCounterpart` 쿼리를 반복 실행하는 N+1 구조였다. 방 60개를 가진 파워유저 조건(k6 20VU/60s)에서 단건 요청 쿼리 수가 **27개 → 8개(-70.4%)**로 줄었고, HTTP p95는 105.05ms → 60.70ms(**-42.2%**), p99는 208.35ms → 88.40ms(**-57.6%**)로 개선됐다. 방마다 읽음 기준점(`lastReadSeq`)이 달라 SQL `GROUP BY` 하나로는 방별 정확한 개수를 낼 수 없어서, "이 페이지의 가장 오래된 기준점보다 뒤에 온 상대방 메시지"까지만 배치로 가져오고 방별 정확한 개수는 메모리에서 다시 필터링하는 방식을 썼다. 기존 단건 메서드(`countUnreadFromCounterpart`)는 그대로 남겨뒀다(호출부가 이번에 바뀐 `findRooms` 한 곳뿐이라 사실상 안 쓰이지만, 리포지토리 공개 메서드라 제거는 범위 밖으로 판단).

---

## 1. 문제 상황

`ChatRoomService.findRooms()`는 커서 페이지네이션으로 방 목록(`ChatRoomSummaryProjection`, 최대 `size`개)을 가져온 뒤, 각 방을 `toSummary()`로 변환한다. `toSummary()`는 방마다:

```java
long unreadCount = chatMessageRepository.countUnreadFromCounterpart(
        row.getRoomId(), memberId, lastReadSeq);
```

를 호출한다 — 즉 페이지 크기가 N이면 목록 조회 하나에 N번의 `COUNT` 쿼리가 추가로 나간다. 기본 페이지 크기가 20이라 일반적인 채팅 목록 로드마다 최소 20번의 추가 쿼리가 발생하고, 이 API는 채팅 목록 화면 진입/새로고침/폴링마다 호출되는 빈도 높은 경로다.

서브에이전트 코드 조사에서 "채팅 미확인 메시지 수 N+1"로 지목된 후보였고(`ChatRoomService.java:127-138`, `:301-321`), 코드 확인 결과 실재하는 패턴임을 확인해 아래에서 실측했다.

---

## 2. 재현 환경

이전 두 후보(count 쿼리 중복 서브쿼리, 진단 요약 배치 조회)와 동일한 샌드박스 환경이다.

| 항목 | 값 |
|---|---|
| 실행 환경 | 격리 리눅스 샌드박스 (Docker 미사용, rootless) |
| CPU / Memory | 2 vCPU / 3.8GB (MySQL+App+k6 공유) |
| Java / Spring Boot | Temurin 21.0.12 / 4.0.7 |
| DB | MySQL 8.0.39, rootless (포트 3307) |
| Connection Pool | HikariCP 기본값, `maximumPoolSize=10` |
| 테스트 데이터 규모 | 기존 5만 건 listing 시드 위에, 파워유저(`chatload_buyer@limit.local`) 1명이 채팅방 **60개**에 참여, 방마다 메시지 15개(홀수 순번은 구매자, 짝수 순번은 상대방 발신 — 상대방 발신 7개/방), 구매자 `lastReadSeq=3`으로 고정(방마다 상대방이 보낸 4·6·8·10·12·14번, 6개가 미확인)(재현 스크립트: `evidence/seed_chat_unread.sql`) |
| 인증 | `POST /api/v1/auth/sessions`로 실제 로그인해 발급받은 JWT 사용 |
| k6 버전 / VU / duration / think time | v0.54.0 / 20 / 60s / 200ms |
| 테스트 endpoint | `GET /api/v1/chat-rooms?size=20` (기본 페이지 크기, 60개 방 중 첫 페이지) — 스크립트: `evidence/k6-chat-rooms.js` |
| 기타 | slow_query_log 전체 활성화(`long_query_time=0`) |
| Before/After 코드 분리 | `git show HEAD:...`로 수정 전 원본 두 파일만 되돌린 별도 빌드로 Before를 측정하고, 같은 세션에서 곧바로 수정본을 재빌드해 After를 측정 — 동일 MySQL 데이터, 동일 머신, 동일 세션에서 앞뒤로 측정 |

---

## 3. Baseline (Before, 원본 코드)

실행 시각(UTC): 2026-08-11T01:49:58Z ~ 01:50:59Z. 원본: `evidence/chatrooms_before_summary.json`.

### 단건 요청 쿼리 수 (60개 방 중 첫 페이지, size=20)

| 항목 | 값 |
|---|---:|
| 요청당 쿼리 수 (slow query log 전수) | **27개** |
| 응답 시간 (단건) | 125.97 ms |

### k6 부하 테스트 (20VU/60s)

| Metric | 값 |
|---|---:|
| 요청 수 | 4,829건 |
| RPS | 79.73 req/s |
| avg | 48.11 ms |
| p50(med) | 39.06 ms |
| p90 | 86.18 ms |
| p95 | 105.05 ms |
| p99 | 208.35 ms |
| max | 618.70 ms |
| Error rate | 0.00% |
| HikariCP acquire avg | 2.00 ms (9.666s / 4,833건, 테스트 전/후 누적값 차분) |
| HikariCP acquire max | 324.75 ms |
| HikariCP active/idle/pending (테스트 종료 후 스냅샷) | 0 / 10 / 0 |
| JVM Threads live | 36(테스트 전) → 47(테스트 후) |

---

## 4. 원인 분석

### 4-1. 방 단위 반복 COUNT 쿼리 (코드 구조 — 확정)

§1에서 설명한 대로 페이지에 담긴 방(이번 조건 20개)마다 `countUnreadFromCounterpart`가 1번씩 호출됐다. 단건 요청 쿼리 수 27개는 대략 "목록 쿼리 1 + 컨텍스트 배치 조회 2~3(닉네임·프로필·상품 정보 등) + 미확인 개수 20 + 인증 관련 조회 2~3"로 설명된다(정확한 내역은 slow log 원문 기준이며, 항목별로 쪼개 세지는 않았다 — `가설`: 대략적 구성).

### 4-2. HikariCP 커넥션 점유 (증상)

`hikaricp_connections_acquire_seconds` 평균이 2.00ms로 낮아 보이지만 최대 324.75ms까지 튄 요청이 있었다 — 20VU가 동시에 27개씩 순차 쿼리를 실행하며 짧은 순간 커넥션을 반복 재획득(get→release→get...)하는 과정에서 경합이 튀는 사례로 추정한다(`가설`: 정확한 원인 분리는 하지 않음).

### 4-3. 왜 방마다 SQL `GROUP BY`로 한 번에 못 세는가

방마다 "몇 번 이후 메시지부터 미확인인가"의 기준(`lastReadSeq`)이 다르다. `SELECT room_id, COUNT(*) ... WHERE room_id IN (...) GROUP BY room_id`처럼 단일 WHERE 조건으로는 방별로 다른 기준점을 표현할 수 없다. 이번 픽스는 "페이지에서 가장 오래된 기준점보다 뒤에 온 상대방 메시지"까지만 배치로 가져오고(과다 포함 가능), 방별 정확한 카운트는 메모리에서 각 방의 실제 기준점으로 다시 걸러내는 방식을 썼다(§7).

---

## 5. 검토한 대안

| 대안 | 기대 성능 | 구현 복잡도 | 정합성 영향 | 부작용/운영 위험 | 비고 |
|---|---|---|---|---|---|
| **A. 최소 기준점 배치 조회 + 메모리 재필터링 (채택)** | 방 수(N)와 무관하게 페이지당 쿼리 1개로 고정 | 낮음 (리포지토리 메서드 1개 + 서비스 메서드 1개, 약 40줄) | 없음 (기존 로직과 동일한 결과를 내도록 회귀 테스트로 확인) | 페이지 안 방들의 기준점 편차가 아주 크면(예: 한 방은 방금 읽음, 다른 방은 몇 달째 안 읽음) 그 사이 구간의 상대방 메시지를 전부 끌어와야 해서, 오래 방치된 방이 섞이면 배치 조회 결과 집합이 커질 수 있음(§12) | 기존 리포지토리 메서드(`findAllByListingId` 활용 패턴과 동일한 "배치로 가져와 메모리에서 재구성"이라는 이번 세션의 반복 패턴 |
| B. 방별 기준점을 담은 임시 테이블과 `JOIN`(SQL VALUES 테이블 생성자) | A와 유사하거나 더 나음 — DB가 방별 필터링까지 끝내서 돌려줌 | 높음 — `@Query(nativeQuery=true)`로 MySQL 8.0.19+ 전용 `VALUES ROW(...) AS t(...)` 문법을 써야 하고, JPQL이 아니라 네이티브 쿼리라 프로젝트의 기존 리포지토리 스타일(JPQL 위주)과 어긋남 | 없음 | MySQL 버전 종속적인 문법이라 이식성이 떨어지고, 팀 내 낯선 패턴이라 유지보수 부담 | 이론상 더 정확하고 결과 집합도 최소화되지만, 이번 변경 규모에 비해 복잡도가 크다고 판단해 보류 |
| C. `lastMessageSeq - lastReadSeq`로 근사 계산(쿼리 자체 제거) | 쿼리 0개 — 가장 빠름 | 매우 낮음 | **부정확** — 방의 메시지 순번은 구매자·판매자 공용 카운터라, 그 사이에 "내가 보낸 메시지"가 섞여 있으면 실제 미확인 개수보다 과대 계산됨(코드 확인: `saveNewMessage`가 발신자 구분 없이 `room.nextMessageSequence()`를 공유) | 미확인 배지 숫자가 틀리게 보임 — 사용자 신뢰도에 직접 영향 | 근본적으로 다른 값을 계산하게 돼 제외 |

---

## 6. 의사결정

**A(최소 기준점 배치 조회 + 메모리 재필터링)를 선택했다.**

- C(산술 근사)는 구현이 가장 간단하지만 실제로 다른 값(부정확한 미확인 개수)을 낼 위험이 있어 제외했다 — 성능보다 정확성이 우선이라고 판단했다.
- B(네이티브 VALUES JOIN)는 이론상 A보다 결과 집합이 작을 수 있지만, 이 프로젝트의 리포지토리들이 전부 JPQL(`@Query` 문자열)로 통일돼 있는데 이번 한 곳만 MySQL 버전 종속 네이티브 SQL을 쓰는 건 일관성을 해친다고 판단했고, 이번 데이터 규모(파워유저 60방)에서 A의 "과다 포함" 부작용이 실측상 문제되지 않았다(§8 쿼리 수 8개로 충분히 낮음).
- A는 기존 세션에서 반복해 온 패턴(매물 단위로 evidence를 배치로 가져와 메모리에서 필터링하던 진단 요약 API 개선과 동일한 접근)이라 팀 코드베이스에 낯설지 않고, 변경 범위도 작다.

---

## 7. 구현

**변경 파일 1: `ChatMessageRepository.java`**

```java
@Query("""
        SELECT message.chatRoomId AS roomId, message.roomSequence AS roomSequence
          FROM ChatMessage message
         WHERE message.chatRoomId IN :roomIds
           AND message.senderId <> :memberId
           AND message.roomSequence > :minLastReadSeq
           AND message.deletedAt IS NULL
        """)
List<UnreadMessageProjection> findCounterpartMessagesSince(
        @Param("roomIds") List<Long> roomIds,
        @Param("memberId") Long memberId,
        @Param("minLastReadSeq") long minLastReadSeq);
```

기존 `countUnreadFromCounterpart(roomId, memberId, lastReadSeq)`는 시그니처·동작을 그대로 뒀다(다른 호출자는 없었지만, 공개 리포지토리 메서드 제거는 이번 변경 범위 밖으로 판단).

**변경 파일 2: `ChatRoomService.java`**

`findRooms()`가 페이지 방 목록을 가져온 직후, 방들의 `lastReadSeq` 중 최솟값을 하한으로 `findCounterpartMessagesSince()`를 1번 호출해 `Map<방id, List<상대방 메시지 순번>>`을 만들고, 방마다 `toSummary()`에서 그 방의 실제 `lastReadSeq`보다 큰 순번만 세도록 바꿨다.

```java
private Map<Long, Long> unreadCountsByRoom(List<ChatRoomSummaryProjection> pageRows, Long memberId) {
    if (pageRows.isEmpty()) return Map.of();
    List<Long> roomIds = pageRows.stream().map(ChatRoomSummaryProjection::getRoomId).toList();
    Map<Long, Long> lastReadSeqByRoom = pageRows.stream().collect(Collectors.toMap(
            ChatRoomSummaryProjection::getRoomId,
            row -> row.getLastReadSeq() == null ? 0L : row.getLastReadSeq()));
    long minLastReadSeq = lastReadSeqByRoom.values().stream().mapToLong(Long::longValue).min().orElse(0L);

    Map<Long, List<Long>> counterpartSequencesByRoom =
            chatMessageRepository.findCounterpartMessagesSince(roomIds, memberId, minLastReadSeq).stream()
                    .collect(Collectors.groupingBy(UnreadMessageProjection::getRoomId,
                            Collectors.mapping(UnreadMessageProjection::getRoomSequence, Collectors.toList())));

    return roomIds.stream().collect(Collectors.toMap(roomId -> roomId, roomId -> {
        long lastReadSeq = lastReadSeqByRoom.getOrDefault(roomId, 0L);
        return counterpartSequencesByRoom.getOrDefault(roomId, List.of()).stream()
                .filter(sequence -> sequence > lastReadSeq).count();
    }));
}
```

**테스트:**

```
./gradlew test --tests "com.c203.limit.domain.chat.*"
BUILD SUCCESSFUL (108 tests, chat 도메인 전체)
```

`ChatRoomServiceTests`에 배치 조회 계약에 맞춰 기존 2건을 갱신하고, 방 2개짜리 페이지에서 배치 조회가 **정확히 1번만** 호출되고(`verify(..., times(1))`), 기존 단건 메서드는 **호출되지 않으며**(`verify(..., never())`), 방별로 서로 다른 기준점을 적용해도 카운트가 정확한지(기준점 이하 값이 섞여 와도 필터링되는지)를 검증하는 회귀 테스트 1건을 추가했다.

**k6 스크립트:** `evidence/k6-chat-rooms.js` (Before/After 동일 스크립트, VU/duration 고정)
**시드 스크립트:** `evidence/seed_chat_unread.sql`

---

## 8. 검증

Before와 동일한 조건(같은 MySQL 데이터, 같은 세션 내 원본↔수정본 재빌드, 같은 k6 스크립트/VU/duration)에서 재측정했다.

실행 시각(UTC): 2026-08-11T01:51:39Z ~ 01:52:40Z. 원본: `evidence/chatrooms_after_summary.json`.

### 단건 요청 쿼리 수

| 항목 | Before | After | Change |
|---|---:|---:|---:|
| 요청당 쿼리 수 | 27개 | **8개** | **-70.4%** |
| 응답 시간 (단건) | 125.97 ms | 93.31 ms | -25.9% |
| 응답의 `unreadCount` 표본(5개 방) | [6, 6, 6, 6, 6] | [6, 6, 6, 6, 6] | 동일 — 값이 바뀌지 않았다는 근거 |

### k6 부하 테스트 (20VU/60s)

| Metric | 값 |
|---|---:|
| 요청 수 | 5,267건 |
| RPS | 87.30 req/s |
| avg | 27.23 ms |
| p50(med) | 21.84 ms |
| p90 | 50.63 ms |
| p95 | 60.70 ms |
| p99 | 88.40 ms |
| max | 320.22 ms |
| Error rate | 0.00% |
| HikariCP acquire avg | 0.672 ms (3.542s / 5,271건) |
| HikariCP acquire max | 138.96 ms |
| HikariCP active/idle/pending (테스트 종료 후 스냅샷) | 0 / 10 / 0 |
| JVM Threads live | 36(테스트 전) → 47(테스트 후) |

기능 회귀는 §7 단위 테스트(chat 도메인 전체 108건)로 확인했고, 실제 HTTP 응답의 `unreadCount` 값이 Before/After 동일함을 수동 확인했다(표본 5개 방 모두 6로 일치 — 시드 설계상 기대값과도 일치).

---

## 9. Before / After

### HTTP 레벨 (`GET /api/v1/chat-rooms?size=20`, k6, 20VU/60s)

| Metric | Before | After | Change |
|---|---:|---:|---:|
| avg | 48.11 ms | 27.23 ms | **-43.4%** |
| p50 | 39.06 ms | 21.84 ms | **-44.1%** |
| p90 | 86.18 ms | 50.63 ms | **-41.3%** |
| p95 | 105.05 ms | 60.70 ms | **-42.2%** |
| p99 | 208.35 ms | 88.40 ms | **-57.6%** |
| max | 618.70 ms | 320.22 ms | -48.3% |
| RPS | 79.73 | 87.30 | +9.5% |
| Error Rate | 0.00% | 0.00% | - |
| 완료 요청 수 (60s) | 4,829 | 5,267 | +9.1% |

### DB 레벨 (단건 요청 쿼리 수)

| Metric | Before | After | Change |
|---|---:|---:|---:|
| 요청당 쿼리 수 | 27개 | 8개 | **-70.4%** |

### 애플리케이션 레벨

| Metric | Before | After | Change |
|---|---:|---:|---:|
| HikariCP acquire avg | 2.00 ms | 0.672 ms | **-66.4%** |
| HikariCP acquire max | 324.75 ms | 138.96 ms | -57.2% |
| HikariCP active/idle/pending (테스트 종료 후 스냅샷) | 0 / 10 / 0 | 0 / 10 / 0 | 변화 없음(§12) |
| JVM Threads live (테스트 후) | 47 | 47 | 변화 없음 |
| CPU / Memory / JVM Heap / GC | N/A | N/A | 측정 안 함 |

---

## 10. 결과 해석

쿼리 수 감소(-70.4%)와 HTTP p95 감소(-42.2%)가 비례하지 않고 쿼리 수 감소폭이 더 크게 나타났다 — 이는 이번 후보의 쿼리들이 앞선 진단 요약 API(단순 인덱스 조회 20개 반복)와 달리, `countUnreadFromCounterpart` 자체가 방마다 `chat_message` 테이블을 `chatRoomId+senderId+roomSequence` 조건으로 스캔하는 집계 쿼리라 개별 비용이 상대적으로 낮았기 때문으로 추정한다(`가설`: 쿼리별 개별 비용을 분리 측정하지는 않았음). 그럼에도 p99 개선폭(-57.6%)이 p95(-42.2%)보다 크게 나타난 것은, HikariCP acquire max가 324.75ms→138.96ms로 줄어든 것과 같은 방향이다 — 쿼리 수가 많을수록 커넥션을 오래 붙잡아 20VU 동시 요청 중 일부가 꼬리 지연(tail latency)을 겪었고, 그 꼬리가 짧아진 것으로 해석한다.

---

## 11. Trade-off

- §5-A에서 밝혔듯, 페이지 안 방들의 읽음 기준점 편차가 크면(오래 방치된 방과 방금 읽은 방이 한 페이지에 섞이면) 배치 조회가 "가장 오래된 기준점 이후 전체" 상대방 메시지를 가져오게 돼, 오래 방치된 방 하나 때문에 다른 방들까지 불필요하게 큰 결과 집합을 만들 수 있다. 이번 시드(전 방 `lastReadSeq=3`으로 균일)에서는 이 부작용이 드러나지 않았다(§12).
- 필드 선택 로직(정확히는 카운트 기준)이 SQL의 `WHERE roomSequence > :lastReadSeq`에서 "SQL은 하한만 거르고, 방별 정확한 필터링은 메모리에서"로 바뀌어, 코드를 처음 보는 사람에게는 왜 정확한 개수가 아니라 하한만 걸었는지 주석 없이는 이해하기 어렵다 — 주석으로 이유를 남겨뒀다(§7).
- 기존 단건 메서드(`countUnreadFromCounterpart`)가 더 이상 프로덕션에서 호출되지 않지만 남겨뒀다 — 죽은 코드가 될 가능성이 있어, 다음에 리포지토리를 정리할 때 실제로 다른 호출자가 없는지 재확인 후 제거를 검토할 필요가 있다.

---

## 12. 남은 한계

- 이번 시드는 파워유저 1명, 방 60개, 방마다 읽음 기준점이 **균일하게 3**으로 고정된 조건이다 — 실제 서비스에서는 방마다 마지막 활동 시각과 읽음 시점이 훨씬 더 흩어져 있을 것이고, §11에서 언급한 "가장 오래된 기준점" 부작용이 이 조건에서는 드러나지 않았다(`가설`: 기준점이 매우 흩어진 조건에서 배치 조회 결과 집합이 커질 가능성이 있으나 측정하지 않음).
- 방마다 메시지 15개(상대방 발신 7개)라는 비교적 작은 규모에서 측정했다 — 채팅이 오래 지속돼 방 하나에 메시지가 수천 개 쌓인 경우, 배치 조회의 "하한 기준 이후 전체"가 여전히 작은 집합을 유지하는지는 확인하지 않았다.
- 단일 실행(v1)만 수행했다 — 동일 조건 반복 측정(v1/v2)으로 변동 폭을 확인하지 않았다.
- 단일 샌드박스 환경(2 vCPU, 3.8GB)에서만 측정했다 — 운영 인프라와 조건이 다르다.
- CPU/Memory/JVM Heap/GC는 측정하지 못했다(N/A).
- HikariCP `active`/`idle`/`pending`은 부하 테스트 종료 후 스냅샷이라 부하 중 실제 포화 여부는 보여주지 못한다 — 누적 지표(`acquire_seconds`)는 유효한 근거로 썼다.
- 실제 운영 트래픽 패턴과 다른 합성 데이터·합성 부하 패턴이다.

---

## 13. 포트폴리오 후보 문장

> 채팅방 목록 API가 페이지에 담긴 방마다 미확인 메시지 개수를 반복 조회하는 것을 slow query log로 확인(파워유저 조건 단건 요청 27쿼리)하고, 방별 읽음 기준점이 서로 달라 SQL GROUP BY로 한 번에 셀 수 없는 제약을 "최소 기준점 배치 조회 + 메모리 재필터링" 방식으로 해결해 쿼리 수를 8개로 70.4% 감소시켰다. k6 20VU/60s 환경에서 HTTP p95 응답 시간을 105ms에서 61ms로 42.2% 개선(p99 208ms→88ms, -57.6%).

수치는 실측값이며, 위 "남은 한계"(균일한 읽음 기준점 조건, 작은 메시지 규모, 단일 실행)를 포트폴리오 본문에 함께 적을 것을 권장한다.

---

## 14. 포트폴리오 상세 작성용 자료

### 문제 상황 요약

채팅방 목록 API가 페이지에 담긴 방(기본 20개)마다 미확인 메시지 개수를 세는 쿼리를 반복 실행하는 N+1 구조였다. 채팅 목록은 진입·새로고침·폴링마다 호출되는 빈도 높은 화면이라 실제 트래픽에 그대로 노출된다.

### 의사결정 과정

가장 빠른 방법은 이미 응답에 있는 `lastMessageSeq`와 `lastReadSeq`의 차이로 미확인 개수를 근사 계산하는 것이었지만, 방의 메시지 순번이 구매자·판매자 공용 카운터라 그 사이에 내가 보낸 메시지가 섞이면 실제보다 과대 계산되는 정확성 문제가 있어 제외했다. MySQL의 `VALUES` 테이블 생성자로 방별 기준점을 조인하는 네이티브 SQL도 검토했지만, 이 프로젝트 리포지토리가 전부 JPQL로 통일돼 있어 일관성을 해친다고 판단했다. 결국 "페이지의 최소 기준점 이후 상대방 메시지"까지만 배치로 가져오고 방별 정확한 개수는 메모리에서 다시 거르는, 정확성과 구현 단순성을 모두 지키는 방식을 선택했다.

### 해결

`ChatMessageRepository`에 `findCounterpartMessagesSince()`를 추가해 페이지 단위로 상대방이 보낸 메시지를 한 번에 가져오고, `ChatRoomService`가 방마다 반복 호출하던 카운트 쿼리를 이 배치 결과에서 방별로 계산하도록 바꿨다. 기존 단건 카운트 메서드는 시그니처·동작을 그대로 남겼다.

### 결과

같은 조건(20VU, 60s, 파워유저 60개 방 조건, 같은 세션 내 원본↔수정본 앞뒤 재측정)에서 단건 요청 쿼리 수가 27개 → 8개(-70.4%), HTTP p95가 105ms → 61ms(-42.2%), p99가 208ms → 88ms(-57.6%)로 개선됐다. 응답의 `unreadCount` 값 자체는 Before/After 동일함을 확인해 정확성을 해치지 않았다는 근거로 남겼다.

### 핵심 근거

- 관련 코드: `backend/src/main/java/com/c203/limit/domain/chat/repository/ChatMessageRepository.java`(`findCounterpartMessagesSince`), `backend/src/main/java/com/c203/limit/domain/chat/service/ChatRoomService.java`(`unreadCountsByRoom`, `toSummary`)
- 관련 커밋: 없음 (워킹 트리 변경, 미커밋 — 기준 커밋 `05d1657`)
- 관련 테스트: `ChatRoomServiceTests`(46건, 배치 단일 호출 검증 포함) — chat 도메인 전체 108건 그린
- 관련 k6 스크립트: `evidence/k6-chat-rooms.js`
- 관련 시드 스크립트: `evidence/seed_chat_unread.sql`
- 관련 원본 결과: `evidence/chatrooms_before_summary.json`, `evidence/chatrooms_after_summary.json`, `evidence/chatrooms_before_hikari_before.txt`, `evidence/chatrooms_before_hikari_after.txt`, `evidence/chatrooms_after_hikari_before.txt`, `evidence/chatrooms_after_hikari_after.txt`, `evidence/chatrooms_before_run_timestamps.txt`, `evidence/chatrooms_after_run_timestamps.txt`
- 관련 Grafana metric: 없음 (모니터링 스택 미구성, §12)

---

## 다음 성능 개선 후보

1. **채팅 미디어 업로드가 트랜잭션 내부에서 S3에 동기 호출하는 구조.** `ChatMediaService.upload()`가 `@Transactional` 안에서 `s3Client.putObject(...)`를 동기 호출한다(최대 100MB 비디오 허용) — 네트워크 I/O 동안 DB 커넥션을 붙잡아 둔다. 이번 세션에서는 실 S3(또는 LocalStack) 없이는 의미 있게 측정하기 어려워 코드 조사만 하고 실측은 보류했다(`가설` 단계, 다음 후보 1순위).
2. **읽음 기준점이 크게 흩어진 조건에서의 재측정.** 이번 시드는 모든 방의 `lastReadSeq`가 균일했다(§12) — 방치된 방과 활발한 방이 섞인 현실적인 분포에서 배치 조회의 "과다 포함" 부작용이 실제로 문제되는지 확인이 필요하다.
3. **결제 스케줄러의 Toss 순차 재조회.** `PaymentReservationExpirationScheduler`가 만료 처리 대상(최대 100건/tick) 중 확인 시도가 있었던 건에 한해 Toss API를 순차 호출한다 — 평소엔 N이 작아 문제되지 않을 가능성이 높지만, Toss 응답 지연/장애 시 tick 전체가 느려질 수 있어 재시도·타임아웃 정책 확인이 필요하다(`가설` 단계, 미측정).

> 노션 "취준/limit 개선사항" 페이지에 토글로 옮겨야 하는데, 이번 세션에서도 Notion 연동이 인증되어 있지 않아 직접 쓰지 못했습니다. 위 항목들을 그대로 토글로 붙여넣으시면 됩니다. Notion 연동을 인증해 주시면 다음부터는 제가 직접 쓸 수 있습니다.
