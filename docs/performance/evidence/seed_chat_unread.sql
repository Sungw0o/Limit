-- 채팅방 목록(GET /api/v1/chat-rooms) 미확인 개수 N+1 측정용 시드.
-- 파워유저 1명(chatload_buyer)이 60개 채팅방에 참여 중이고, 방마다 상대방이 보낸 메시지가 있어
-- 첫 페이지(size=20, 기본값) 조회 시 "미확인 개수 계산"이 방마다 반복되는지 확인할 수 있게 한다.
-- Idempotent: 자신이 만든 행을 이메일/마커로 정리한 뒤 다시 넣는다.

SET foreign_key_checks = 0;

DELETE FROM chat_message WHERE chat_room_id IN (
    SELECT id FROM chat_room WHERE buyer_id IN (SELECT user_id FROM user_account WHERE email = 'chatload_buyer@limit.local')
);
DELETE FROM chat_room_participant WHERE chat_room_id IN (
    SELECT id FROM chat_room WHERE buyer_id IN (SELECT user_id FROM user_account WHERE email = 'chatload_buyer@limit.local')
);
DELETE FROM chat_room WHERE buyer_id IN (SELECT user_id FROM user_account WHERE email = 'chatload_buyer@limit.local');
DELETE FROM user_account WHERE email = 'chatload_buyer@limit.local';

-- 로그인 테스트용 비밀번호: LoadTest123! (bcrypt, cost 10, 로컬 테스트 전용 — 실사용자 자격증명 아님)
INSERT INTO user_account (email, password, nickname, phone, status, marketing_opt_in, email_verified_at, created_at, updated_at)
VALUES ('chatload_buyer@limit.local', '$2b$10$/T0z.dJ74M8yBLfaFbKtQe4RNTtUfUeI28fqyc2N0CYPA0NpKRm..', 'chatload_buyer', '01099998888', 'ACTIVE', b'0', NOW(), NOW(), NOW());

SET @buyer_id := (SELECT user_id FROM user_account WHERE email = 'chatload_buyer@limit.local');

DROP TABLE IF EXISTS digits3;
CREATE TABLE digits3 (d INT);
INSERT INTO digits3 VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);

DROP TABLE IF EXISTS room_slot;
CREATE TABLE room_slot (n INT PRIMARY KEY);
INSERT INTO room_slot (n)
SELECT d1.d + d2.d*10
FROM digits3 d1, digits3 d2
WHERE d1.d + d2.d*10 < 60;

-- 상대방(seller_id)은 기존 seed_buyer_* 계정 30명을 재사용한다(순수 인프라 목적, 역할 의미는 없음).
DROP TABLE IF EXISTS counterpart_rn;
CREATE TABLE counterpart_rn (rn INT PRIMARY KEY, user_id BIGINT);
SET @crn := -1;
INSERT INTO counterpart_rn (rn, user_id)
SELECT (@crn := @crn + 1), user_id FROM user_account WHERE email LIKE 'seed_buyer_%@limit.local' ORDER BY user_id LIMIT 30;
SET @counterpart_count := (SELECT COUNT(*) FROM counterpart_rn);

INSERT INTO chat_room (listing_id, transaction_id, buyer_id, seller_id, status, last_message_id, last_message_seq, last_message_at, created_at, updated_at, closed_at)
SELECT s.n + 1, NULL, @buyer_id, cr.user_id, 'ACTIVE', NULL, 15, NOW(), DATE_SUB(NOW(), INTERVAL (s.n % 30) DAY), NOW(), NULL
FROM room_slot s
JOIN counterpart_rn cr ON cr.rn = s.n % @counterpart_count;

DROP TABLE IF EXISTS new_room;
CREATE TABLE new_room (rn INT PRIMARY KEY, id BIGINT, seller_id BIGINT);
SET @nrn := -1;
INSERT INTO new_room (rn, id, seller_id)
SELECT (@nrn := @nrn + 1), id, seller_id FROM chat_room WHERE buyer_id = @buyer_id ORDER BY id;

-- 참여자: 구매자는 last_read_seq=3(방마다 뒤에 온 상대방 메시지가 미확인으로 남게), 상대방은 다 읽음(15).
INSERT INTO chat_room_participant (chat_room_id, user_id, participant_role, last_read_seq, joined_at, left_at, created_at, updated_at)
SELECT id, @buyer_id, 'BUYER', 3, DATE_SUB(NOW(), INTERVAL 30 DAY), NULL, DATE_SUB(NOW(), INTERVAL 30 DAY), NOW()
FROM new_room;

INSERT INTO chat_room_participant (chat_room_id, user_id, participant_role, last_read_seq, joined_at, left_at, created_at, updated_at)
SELECT id, seller_id, 'SELLER', 15, DATE_SUB(NOW(), INTERVAL 30 DAY), NULL, DATE_SUB(NOW(), INTERVAL 30 DAY), NOW()
FROM new_room;

-- 메시지 15개/방, 홀수 순번은 구매자가, 짝수 순번은 상대방이 보낸 것으로 번갈아(짝수 7개=상대방 발신).
-- 구매자 last_read_seq=3이라 상대방이 보낸 4,6,8,10,12,14번(6개)이 방마다 "미확인"이어야 한다.
DROP TABLE IF EXISTS msg_slot;
CREATE TABLE msg_slot (n INT PRIMARY KEY);
INSERT INTO msg_slot (n)
SELECT d1.d + d2.d*10
FROM digits3 d1, digits3 d2
WHERE d1.d + d2.d*10 < 15;

INSERT INTO chat_message (chat_room_id, room_sequence, sender_id, client_message_id, message_type, content, status, sent_at, deleted_at)
SELECT nr.id, m.n + 1,
       CASE WHEN (m.n + 1) % 2 = 1 THEN @buyer_id ELSE nr.seller_id END,
       UUID_TO_BIN(UUID()), 'TEXT',
       CONCAT('load test message ', m.n + 1), 'SENT',
       DATE_SUB(NOW(), INTERVAL (15 - m.n) HOUR), NULL
FROM new_room nr
JOIN msg_slot m ON 1=1;

UPDATE chat_room cr
JOIN (
    SELECT chat_room_id, MAX(id) AS last_id, MAX(room_sequence) AS last_seq, MAX(sent_at) AS last_at
    FROM chat_message
    WHERE chat_room_id IN (SELECT id FROM new_room)
    GROUP BY chat_room_id
) lm ON lm.chat_room_id = cr.id
SET cr.last_message_id = lm.last_id, cr.last_message_seq = lm.last_seq, cr.last_message_at = lm.last_at;

SET foreign_key_checks = 1;

DROP TABLE IF EXISTS digits3;
DROP TABLE IF EXISTS room_slot;
DROP TABLE IF EXISTS counterpart_rn;
DROP TABLE IF EXISTS new_room;
DROP TABLE IF EXISTS msg_slot;

SELECT 'chat_rooms' t, COUNT(*) c FROM chat_room WHERE buyer_id = @buyer_id
UNION ALL SELECT 'chat_messages', COUNT(*) FROM chat_message WHERE chat_room_id IN (SELECT id FROM chat_room WHERE buyer_id = @buyer_id)
UNION ALL SELECT 'buyer_id', @buyer_id;
