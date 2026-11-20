import http from 'k6/http';
import { check, sleep } from 'k6';

// Baseline / After load test for GET /api/v1/products (상품 목록/검색 API).
// Fixed conditions (must stay identical between Before/After runs):
//   - VUs: 20, duration: 60s (constant-vus executor)
//   - think time: 200ms between requests per VU
//   - target: http://127.0.0.1:18080
//   - mix: 40% keyword search, 30% keyword+verifiedCount range, 30% plain paginated browse
const BASE_URL = 'http://127.0.0.1:18080';

const keywords = ['급처', '풀박스', '미개봉', 'S급', 'A급', 'Galaxy', 'iPhone', 'iPad', '무하자', '직거래환영'];

export const options = {
  scenarios: {
    product_list: {
      executor: 'constant-vus',
      vus: 20,
      duration: '60s',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

export default function () {
  const r = Math.random();
  const page = Math.floor(Math.random() * 20); // browse across first 20 pages
  let url;
  if (r < 0.4) {
    const kw = keywords[Math.floor(Math.random() * keywords.length)];
    url = `${BASE_URL}/api/v1/products?keyword=${encodeURIComponent(kw)}&page=${page}&size=20&sort=createdAt,desc`;
  } else if (r < 0.7) {
    const kw = keywords[Math.floor(Math.random() * keywords.length)];
    url = `${BASE_URL}/api/v1/products?keyword=${encodeURIComponent(kw)}&minVerifiedCount=1&maxVerifiedCount=4&page=${page}&size=20&sort=createdAt,desc`;
  } else {
    url = `${BASE_URL}/api/v1/products?page=${page}&size=20&sort=createdAt,desc`;
  }

  const res = http.get(url);
  check(res, {
    'status is 200': (res) => res.status === 200,
  });
  sleep(0.2);
}
