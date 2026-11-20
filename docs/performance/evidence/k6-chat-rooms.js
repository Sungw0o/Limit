import http from 'k6/http';
import { check, sleep } from 'k6';

// GET /api/v1/chat-rooms?size=20 (인증 필요, chatload_buyer 로그인 후 JWT 사용)
// Fixed conditions: VUs 20, duration 60s, constant-vus, think time 200ms.
const BASE_URL = 'http://127.0.0.1:18080';

export const options = {
  scenarios: {
    chat_rooms: {
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
  const res = http.post(
    `${BASE_URL}/api/v1/auth/sessions`,
    JSON.stringify({ email: 'chatload_buyer@limit.local', password: 'LoadTest123!' }),
    { headers: { 'Content-Type': 'application/json' } },
  );
  const token = res.json('data.accessToken');
  if (!token) {
    throw new Error(`login failed: status=${res.status} body=${res.body}`);
  }
  return { token };
}

export default function (data) {
  const res = http.get(`${BASE_URL}/api/v1/chat-rooms?size=20`, {
    headers: { Authorization: `Bearer ${data.token}` },
  });
  check(res, {
    'status is 200': (res) => res.status === 200,
  });
  sleep(0.2);
}
