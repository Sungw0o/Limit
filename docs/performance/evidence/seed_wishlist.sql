-- Adds wishlist/chat_room concentration data for two follow-up experiments:
--   1) "인기 상품" 상세조회: 소수 listing에 다수 buyer의 wishlist/chat_room이 몰린 경우
--   2) "파워유저" 위시리스트 목록: 소수 user가 다수 listing을 관심상품 등록한 경우
-- Idempotent: cleans up its own rows by email/description marker before inserting.

SET foreign_key_checks = 0;

-- cleanup
DELETE FROM wishlist WHERE user_id IN (SELECT user_id FROM user_account WHERE email LIKE 'seed_buyer_%@limit.local' OR email LIKE 'loadtest_power_%@limit.local');
DELETE FROM chat_room WHERE buyer_id IN (SELECT user_id FROM user_account WHERE email LIKE 'seed_buyer_%@limit.local');
DELETE FROM user_account WHERE email LIKE 'seed_buyer_%@limit.local' OR email LIKE 'loadtest_power_%@limit.local';

-- 1) generic buyer pool (2000) for hot-listing concentration
DROP TABLE IF EXISTS digits2;
CREATE TABLE digits2 (d INT);
INSERT INTO digits2 VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);

DROP TABLE IF EXISTS seq_2000;
CREATE TABLE seq_2000 (n INT PRIMARY KEY);
INSERT INTO seq_2000 (n)
SELECT d1.d + d2.d*10 + d3.d*100 + d4.d*1000
FROM digits2 d1, digits2 d2, digits2 d3, digits2 d4
WHERE d1.d + d2.d*10 + d3.d*100 + d4.d*1000 < 2000;

INSERT INTO user_account (email, password, nickname, phone, status, marketing_opt_in, created_at, updated_at)
SELECT
  CONCAT('seed_buyer_', n, '@limit.local'),
  '$2b$10$8iAitkCkh1WzUDPmLS9NXebB7WmQkQlBkbK8BHH6njfn9UYIttzAS',
  CONCAT('seed_buyer_', n),
  CONCAT('011', LPAD(n, 8, '0')),
  'ACTIVE', b'0', NOW(), NOW()
FROM seq_2000;

DROP TABLE IF EXISTS buyer_rn;
CREATE TABLE buyer_rn (rn INT PRIMARY KEY, user_id BIGINT);
SET @brn := -1;
INSERT INTO buyer_rn (rn, user_id)
SELECT (@brn := @brn + 1), user_id FROM user_account WHERE email LIKE 'seed_buyer_%@limit.local' ORDER BY user_id;
SET @buyer_count := (SELECT COUNT(*) FROM buyer_rn);

-- hot listings: 3 listings get up to 1500 wishlist + 1500 chat_room rows each
DROP TABLE IF EXISTS hot_listing;
CREATE TABLE hot_listing (id BIGINT PRIMARY KEY, seller_id BIGINT);
INSERT INTO hot_listing (id, seller_id)
SELECT id, seller_id FROM listing WHERE id IN (1, 1000, 25000);

DROP TABLE IF EXISTS wl_slot;
CREATE TABLE wl_slot (n INT PRIMARY KEY);
INSERT INTO wl_slot (n)
SELECT d1.d + d2.d*10 + d3.d*100
FROM digits2 d1, digits2 d2, digits2 d3
WHERE d1.d + d2.d*10 + d3.d*100 < 1500;

INSERT INTO wishlist (user_id, listing_id, created_at)
SELECT br.user_id, hl.id, DATE_SUB(NOW(), INTERVAL (s.n % 200) DAY)
FROM hot_listing hl
JOIN wl_slot s
JOIN buyer_rn br ON br.rn = s.n % @buyer_count;

INSERT INTO chat_room (listing_id, buyer_id, seller_id, status, last_message_id, last_message_seq, last_message_at, created_at, updated_at, closed_at)
SELECT hl.id, br.user_id, hl.seller_id, 'ACTIVE', NULL, 0, NULL,
       DATE_SUB(NOW(), INTERVAL (s.n % 200) DAY), DATE_SUB(NOW(), INTERVAL (s.n % 200) DAY), NULL
FROM hot_listing hl
JOIN wl_slot s
JOIN buyer_rn br ON br.rn = (s.n + 500) % @buyer_count;

-- 2) power users (5) who each favorite 1000 distinct listings
INSERT INTO user_account (email, password, nickname, phone, status, marketing_opt_in, email_verified_at, created_at, updated_at)
VALUES
 ('loadtest_power_0@limit.local', '$2b$10$8iAitkCkh1WzUDPmLS9NXebB7WmQkQlBkbK8BHH6njfn9UYIttzAS', 'loadtest_power_0', '01099990000', 'ACTIVE', b'0', NOW(), NOW(), NOW()),
 ('loadtest_power_1@limit.local', '$2b$10$8iAitkCkh1WzUDPmLS9NXebB7WmQkQlBkbK8BHH6njfn9UYIttzAS', 'loadtest_power_1', '01099990001', 'ACTIVE', b'0', NOW(), NOW(), NOW()),
 ('loadtest_power_2@limit.local', '$2b$10$8iAitkCkh1WzUDPmLS9NXebB7WmQkQlBkbK8BHH6njfn9UYIttzAS', 'loadtest_power_2', '01099990002', 'ACTIVE', b'0', NOW(), NOW(), NOW()),
 ('loadtest_power_3@limit.local', '$2b$10$8iAitkCkh1WzUDPmLS9NXebB7WmQkQlBkbK8BHH6njfn9UYIttzAS', 'loadtest_power_3', '01099990003', 'ACTIVE', b'0', NOW(), NOW(), NOW()),
 ('loadtest_power_4@limit.local', '$2b$10$8iAitkCkh1WzUDPmLS9NXebB7WmQkQlBkbK8BHH6njfn9UYIttzAS', 'loadtest_power_4', '01099990004', 'ACTIVE', b'0', NOW(), NOW(), NOW());

DROP TABLE IF EXISTS power_user;
CREATE TABLE power_user (rn INT PRIMARY KEY, user_id BIGINT);
SET @prn := -1;
INSERT INTO power_user (rn, user_id)
SELECT (@prn := @prn + 1), user_id FROM user_account WHERE email LIKE 'loadtest_power_%@limit.local' ORDER BY user_id;

DROP TABLE IF EXISTS pl_slot;
CREATE TABLE pl_slot (n INT PRIMARY KEY);
INSERT INTO pl_slot (n)
SELECT d1.d + d2.d*10 + d3.d*100
FROM digits2 d1, digits2 d2, digits2 d3
WHERE d1.d + d2.d*10 + d3.d*100 < 1000;

INSERT INTO wishlist (user_id, listing_id, created_at)
SELECT pu.user_id, l.id, DATE_SUB(NOW(), INTERVAL (s.n % 300) DAY)
FROM power_user pu
JOIN pl_slot s ON 1=1
JOIN listing l ON l.id = ((s.n * 37 + pu.rn * 9973) % 50000) + 1
ON DUPLICATE KEY UPDATE created_at = VALUES(created_at);

SET foreign_key_checks = 1;

DROP TABLE IF EXISTS digits2;
DROP TABLE IF EXISTS seq_2000;
DROP TABLE IF EXISTS buyer_rn;
DROP TABLE IF EXISTS hot_listing;
DROP TABLE IF EXISTS wl_slot;
DROP TABLE IF EXISTS power_user;
DROP TABLE IF EXISTS pl_slot;

SELECT 'buyers' t, COUNT(*) c FROM user_account WHERE email LIKE 'seed_buyer_%@limit.local'
UNION ALL SELECT 'power_users', COUNT(*) FROM user_account WHERE email LIKE 'loadtest_power_%@limit.local'
UNION ALL SELECT 'wishlist_total', COUNT(*) FROM wishlist
UNION ALL SELECT 'chat_room_total', COUNT(*) FROM chat_room
UNION ALL SELECT 'wishlist_hot_1', COUNT(*) FROM wishlist WHERE listing_id=1
UNION ALL SELECT 'wishlist_hot_1000', COUNT(*) FROM wishlist WHERE listing_id=1000
UNION ALL SELECT 'wishlist_hot_25000', COUNT(*) FROM wishlist WHERE listing_id=25000
UNION ALL SELECT 'power_user_0_favs', (SELECT COUNT(*) FROM wishlist w JOIN user_account u ON u.user_id=w.user_id WHERE u.email='loadtest_power_0@limit.local');
