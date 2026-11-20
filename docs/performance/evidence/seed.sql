-- Seed data for GET /api/v1/products performance baseline test.
-- Target scale: 50,000 listings (ON_SALE, publicly visible), ~5 checklist items/listing,
-- 3 images/listing (1 THUMBNAIL). Deterministic-ish distribution via modulo, not pure random,
-- so runs are reproducible if re-seeded.
-- NOTE: helper tables are regular (non-TEMPORARY) tables because MySQL disallows
-- self-joining the same TEMPORARY table more than once in one query; they are dropped at the end.

SET foreign_key_checks = 0;

-- 0) cleanup: allow re-running this script idempotently
DELETE FROM listing_image WHERE listing_id IN (SELECT id FROM listing WHERE description LIKE '%(seed #%');
DELETE FROM listing_checklist_item WHERE listing_id IN (SELECT id FROM listing WHERE description LIKE '%(seed #%');
DELETE FROM listing WHERE description LIKE '%(seed #%';
DELETE FROM seller WHERE user_id IN (SELECT user_id FROM user_account WHERE email LIKE 'seed_seller_%@limit.local');
DELETE FROM user_account WHERE email LIKE 'seed_seller_%@limit.local';

-- 1) sellers (500 users + 500 sellers)
DROP TABLE IF EXISTS digits;
CREATE TABLE digits (d INT);
INSERT INTO digits VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);

DROP TABLE IF EXISTS seq_500;
CREATE TABLE seq_500 AS
SELECT d1.d + d2.d*10 + d3.d*100 AS n
FROM digits d1, digits d2, digits d3
WHERE d1.d + d2.d*10 + d3.d*100 < 500;

INSERT INTO user_account
  (email, password, nickname, phone, status, marketing_opt_in, created_at, updated_at)
SELECT
  CONCAT('seed_seller_', n, '@limit.local'),
  '$2a$10$abcdefghijklmnopqrstuuJXQpZ0k0k0k0k0k0k0k0k0k0k0k0k0',
  CONCAT('seed_seller_', n),
  CONCAT('010', LPAD(n, 8, '0')),
  'ACTIVE',
  b'0',
  DATE_SUB(NOW(), INTERVAL (365 - (n % 365)) DAY),
  DATE_SUB(NOW(), INTERVAL (365 - (n % 365)) DAY)
FROM seq_500;

INSERT INTO seller
  (user_id, seller_type, status, country_code, business_name,
   settlement_bank_name, settlement_account_holder, settlement_account_last4,
   created_at, updated_at)
SELECT
  u.user_id, 'INDIVIDUAL', 'ACTIVE', 'KR', NULL,
  '국민은행', u.nickname, LPAD(u.user_id, 4, '0'),
  u.created_at, u.created_at
FROM user_account u
WHERE u.email LIKE 'seed_seller_%@limit.local';

-- 2) leaf categories that have a PUBLISHED checklist template
DROP TABLE IF EXISTS leaf_cat;
CREATE TABLE leaf_cat (
  rn INT PRIMARY KEY,
  category_id BIGINT,
  category_name VARCHAR(100),
  template_id BIGINT
);
SET @rn := -1;
INSERT INTO leaf_cat (rn, category_id, category_name, template_id)
SELECT (@rn := @rn + 1), c.id, c.name, ct.id
FROM category c
JOIN checklist_template ct ON ct.category_id = c.id AND ct.status = 'PUBLISHED'
ORDER BY c.id;

SET @leaf_count := (SELECT COUNT(*) FROM leaf_cat);

-- 3) sellers row-numbered
DROP TABLE IF EXISTS seller_rn;
CREATE TABLE seller_rn (
  rn INT PRIMARY KEY,
  seller_id BIGINT
);
SET @sn := -1;
INSERT INTO seller_rn (rn, seller_id)
SELECT (@sn := @sn + 1), seller_id FROM seller ORDER BY seller_id;
SET @seller_count := (SELECT COUNT(*) FROM seller_rn);

-- 4) keyword / condition / region pools
DROP TABLE IF EXISTS kw_pool;
CREATE TABLE kw_pool (rn INT PRIMARY KEY, kw VARCHAR(20));
INSERT INTO kw_pool VALUES
 (0,'급처'),(1,'풀박스'),(2,'미개봉'),(3,'생활기스'),(4,'S급'),(5,'A급'),
 (6,'무하자'),(7,'가격내림'),(8,'직거래환영'),(9,'박스풀구성');

DROP TABLE IF EXISTS region_pool;
CREATE TABLE region_pool (rn INT PRIMARY KEY, region VARCHAR(50));
INSERT INTO region_pool VALUES
 (0,'서울 강남구'),(1,'서울 마포구'),(2,'서울 송파구'),(3,'경기 성남시'),
 (4,'경기 수원시'),(5,'부산 해운대구'),(6,'대구 수성구'),(7,'인천 연수구'),
 (8,'대전 유성구'),(9,'광주 서구');

-- 5) 50,000 listing sequence numbers
DROP TABLE IF EXISTS seq_50000;
CREATE TABLE seq_50000 (n INT PRIMARY KEY);
INSERT INTO seq_50000 (n)
SELECT d1.d + d2.d*10 + d3.d*100 + d4.d*1000 + d5.d*10000
FROM digits d1, digits d2, digits d3, digits d4, digits d5
WHERE d1.d + d2.d*10 + d3.d*100 + d4.d*1000 + d5.d*10000 < 50000;

-- 6) listing rows
INSERT INTO listing (
  seller_id, category_id, device_model_id, device_variant_id,
  custom_manufacturer, custom_model_name, title, description, price, color,
  storage_gb, screen_size_inches, memory_gb, connectivity, spec_snapshot, view_count,
  trade_region, checklist_template_id, precheck_completed, draft_step, web_device_check_results,
  status, moderation_status, suspended_reason, buyer_id, reserved_at, reserved_until, paid_at,
  handed_over_at, auto_confirm_at, confirmed_at, settled_at, version, deleted_at, created_at, updated_at
)
SELECT
  sr.seller_id,
  lc.category_id,
  NULL, NULL, NULL, NULL,
  CONCAT(kw.kw, ' ', lc.category_name, ' 팝니다 #', n.n),
  CONCAT('상태 좋은 ', lc.category_name, ' 판매합니다. 시리얼/구성품 확인 가능하며 직거래 우대합니다. (seed #', n.n, ')'),
  (300000 + (n.n % 400) * 15000),
  NULL, NULL, NULL, NULL, NULL, NULL,
  0,
  rg.region,
  lc.template_id,
  b'1',
  5,
  NULL,
  'ON_SALE', 'NORMAL', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
  0,
  NULL,
  DATE_SUB(NOW(), INTERVAL (n.n % 365) DAY) - INTERVAL (n.n % 86000) SECOND,
  DATE_SUB(NOW(), INTERVAL (n.n % 365) DAY) - INTERVAL (n.n % 86000) SECOND
FROM seq_50000 n
JOIN leaf_cat lc ON lc.rn = n.n % @leaf_count
JOIN seller_rn sr ON sr.rn = n.n % @seller_count
JOIN kw_pool kw ON kw.rn = n.n % 10
JOIN region_pool rg ON rg.rn = (n.n DIV 7) % 10;

-- 7) checklist items per listing (mirrors template items; completion status pseudo-random)
INSERT INTO listing_checklist_item (
  listing_id, template_item_id, item_code, item_origin, feature_code, name, capture_guide,
  evidence_type, automation_type, parser_type, is_required, allowed_formats, min_count, max_count,
  min_duration_sec, max_duration_sec, max_file_size_mb, visible_to_buyer, privacy_masking_required,
  completion_status, device_check_result, display_order, manual_model_name, manual_storage_capacity,
  manual_os_version, manual_cpu
)
SELECT
  l.id, cti.id, cti.item_code, 'BASE', NULL, cti.name, cti.capture_guide,
  cti.evidence_type, cti.automation_type, cti.parser_type, cti.is_required, cti.allowed_formats,
  cti.min_count, cti.max_count, cti.min_duration_sec, cti.max_duration_sec, cti.max_file_size_mb,
  cti.visible_to_buyer, cti.privacy_masking_required,
  CASE MOD(l.id + cti.id, 5)
    WHEN 0 THEN 'PENDING'
    WHEN 1 THEN 'IN_PROGRESS'
    ELSE 'COMPLETED'
  END,
  NULL, cti.display_order, NULL, NULL, NULL, NULL
FROM listing l
JOIN checklist_template_item cti ON cti.checklist_template_id = l.checklist_template_id
WHERE l.description LIKE '%(seed #%';

-- 8) images per listing (1 THUMBNAIL + 2 GENERAL)
DROP TABLE IF EXISTS img_slot;
CREATE TABLE img_slot (rn INT PRIMARY KEY, image_type VARCHAR(20));
INSERT INTO img_slot VALUES (0,'THUMBNAIL'),(1,'GENERAL'),(2,'GENERAL');

INSERT INTO listing_image (listing_id, image_type, display_order, s3_key, cdn_url, mime_type, created_at)
SELECT
  l.id, s.image_type, s.rn,
  CONCAT('seed/listing/', l.id, '/', s.rn, '.jpg'),
  CONCAT('https://cdn.limit.local/seed/', l.id, '/', s.rn, '.jpg'),
  'image/jpeg',
  l.created_at
FROM listing l
JOIN img_slot s
WHERE l.description LIKE '%(seed #%';

SET foreign_key_checks = 1;

DROP TABLE IF EXISTS digits;
DROP TABLE IF EXISTS seq_500;
DROP TABLE IF EXISTS leaf_cat;
DROP TABLE IF EXISTS seller_rn;
DROP TABLE IF EXISTS kw_pool;
DROP TABLE IF EXISTS region_pool;
DROP TABLE IF EXISTS seq_50000;
DROP TABLE IF EXISTS img_slot;

SELECT 'user_account' t, COUNT(*) c FROM user_account
UNION ALL SELECT 'seller', COUNT(*) FROM seller
UNION ALL SELECT 'listing', COUNT(*) FROM listing
UNION ALL SELECT 'listing_checklist_item', COUNT(*) FROM listing_checklist_item
UNION ALL SELECT 'listing_image', COUNT(*) FROM listing_image;
