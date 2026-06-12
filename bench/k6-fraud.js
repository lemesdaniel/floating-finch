// Bench local floating-finch — POST /fraud-score
// Uso: k6 run -e BASE=http://localhost:9999 bench/k6-fraud.js
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  vus: 150,
  duration: '30s',
  summaryTrendStats: ['avg', 'min', 'med', 'p(95)', 'p(99)', 'max'],
};

const BASE = __ENV.BASE || 'http://localhost:9999';

function payload(i) {
  const hasLast = i % 3 !== 0;
  const last = hasLast
    ? `{"timestamp":"2026-01-15T${String(10 + (i % 12)).padStart(2, '0')}:23:00Z","km_from_current":${(i * 7) % 900}.5`+`}`
    : 'null';
  const mccs = ['5411', '5812', '7995', '5999', '4511'];
  return `{"id":"tx-${i}","transaction":{"amount":${(i % 9000) + 12}.5,"installments":${(i % 12) + 1},"requested_at":"2026-01-15T${String(i % 24).padStart(2, '0')}:45:30Z"},"customer":{"avg_amount":${(i % 3000) + 50}.0,"tx_count_24h":${i % 20},"known_merchants":["m-1","m-2"]},"merchant":{"id":"m-${i % 5}","mcc":"${mccs[i % 5]}","avg_amount":${(i % 5000) + 100}.0},"terminal":{"is_online":${i % 2 === 0},"card_present":${i % 4 !== 0},"km_from_home":${(i * 3) % 1000}.2},"last_transaction":${last}}`;
}

// Pré-gera 256 payloads variados (evita custo de string-build no loop)
const payloads = [];
for (let i = 0; i < 256; i++) payloads.push(payload(i));

const params = { headers: { 'Content-Type': 'application/json' } };

export default function () {
  const i = (__VU * 7919 + __ITER) % 256;
  const res = http.post(`${BASE}/fraud-score`, payloads[i], params);
  check(res, {
    'status 200': (r) => r.status === 200,
    'has fraud_count': (r) => r.body && r.body.includes('fraud'),
  });
}
