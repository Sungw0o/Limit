import http from 'k6/http';
import { check, sleep } from 'k6';

// GET /api/v1/members/me/favorites for a "power user" with 1000 favorited listings.
// Fixed conditions: VUs 20, duration 60s, constant-vus, think time 200ms.
// All VUs share one power user's token (5 power users, round-robin) since the point is to
// measure the per-request cost of a large favorites list, not per-user isolation.
const BASE_URL = 'http://127.0.0.1:18080';

export const options = {
  scenarios: {
    favorites: {
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

export function setup() {
  const tokens = [];
  for (let i = 0; i < 5; i++) {
    const res = http.post(
      `${BASE_URL}/api/v1/auth/sessions`,
      JSON.stringify({ email: `loadtest_power_${i}@limit.local`, password: 'Testpass1!' }),
      { headers: { 'Content-Type': 'application/json' } }
    );
    const body = res.json();
    tokens.push(body.data.accessToken);
  }
  return { tokens };
}

export default function (data) {
  const token = data.tokens[Math.floor(Math.random() * data.tokens.length)];
  const page = Math.floor(Math.random() * 10); // browse first 10 pages of ~1000 favorites (size 20 -> 50 pages total)
  const res = http.get(`${BASE_URL}/api/v1/members/me/favorites?page=${page}&size=20`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  check(res, {
    'status is 200': (res) => res.status === 200,
  });
  sleep(0.2);
}
