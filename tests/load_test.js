import http from 'k6/http';
import { check, sleep } from 'k6';

// Replace with your actual endpoint
const API_URL = 'https://9k842t72e7.execute-api.us-east-1.amazonaws.com/';

export const options = {
  scenarios: {
    // Scenario 1: steady traffic — should stay under limit
    steady_traffic: {
      executor: 'constant-arrival-rate',
      rate: 5,              // 5 requests per second
      timeUnit: '1s',
      duration: '30s',
      preAllocatedVUs: 10,
    },
    // Scenario 2: burst traffic — should trigger 429s
    burst_traffic: {
      executor: 'constant-arrival-rate',
      rate: 20,             // 20 requests per second
      timeUnit: '1s',
      duration: '30s',
      preAllocatedVUs: 30,
      startTime: '35s',     // starts after steady traffic finishes
    },
  },
};

export default function () {
  const res = http.get(API_URL, {
    headers: {
      // Simulate different users
      'x-api-key': `user-${Math.floor(Math.random() * 5)}`,
    },
  });

  check(res, {
    'status is 200 or 429': (r) => r.status === 200 || r.status === 429,
    'has rate limit headers': (r) => r.headers['X-Ratelimit-Limit'] !== undefined,
  });

  sleep(0.1);
}