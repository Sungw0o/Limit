import http from 'k6/http';
import { check, sleep } from 'k6';

// GET /api/v1/products/{id} for "hot" listings with ~1000 wishlist + ~1000 chat_room rows each.
// Fixed conditions: VUs 20, duration 60s, constant-vus, think time 200ms.
const BASE_URL = 'http://127.0.0.1:18080';
const HOT_IDS = [1, 1000, 25000];

export const options = {
  scenarios: {
    product_detail_hot: {
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
  const id = HOT_IDS[Math.floor(Math.random() * HOT_IDS.length)];
  const res = http.get(`${BASE_URL}/api/v1/products/${id}`);
  check(res, {
    'status is 200': (res) => res.status === 200,
  });
  sleep(0.2);
}
