import http from 'k6/http';
import { check, sleep } from 'k6';

// GET /api/v1/inspections/products/{productId}/diagnosis-summary (인증 불필요, 공개 조회)
// Fixed conditions: VUs 20, duration 60s, constant-vus, think time 200ms.
const BASE_URL = 'http://127.0.0.1:18080';

export const options = {
  scenarios: {
    diagnosis_summary: {
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
  const res = http.get(`${BASE_URL}/api/v1/inspections/products/${id}/diagnosis-summary`);
  check(res, {
    'status is 200': (res) => res.status === 200,
  });
  sleep(0.2);
}
