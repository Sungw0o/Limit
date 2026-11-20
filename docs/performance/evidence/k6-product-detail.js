import http from 'k6/http';
import { check, sleep } from 'k6';

// Baseline load test for GET /api/v1/products/{id} (상품 상세 조회 API).
// Fixed conditions: VUs 20, duration 60s, constant-vus, think time 200ms,
// target http://127.0.0.1:18080, productId uniform-random over seeded ON_SALE listings (1..50000).
const BASE_URL = 'http://127.0.0.1:18080';

export const options = {
  scenarios: {
    product_detail: {
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
  const id = Math.floor(Math.random() * 50000) + 1;
  const res = http.get(`${BASE_URL}/api/v1/products/${id}`);
  check(res, {
    'status is 200': (res) => res.status === 200,
  });
  sleep(0.2);
}
