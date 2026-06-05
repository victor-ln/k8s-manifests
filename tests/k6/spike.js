import http from 'k6/http';
import { check } from 'k6'; // NOVIDADE: Importando o módulo de asserções

export const options = {
  stages: [
    { duration: '1m', target: 60 },
    { duration: '1m', target: 120 },
    { duration: '1m', target: 200 },
  ],
  // NOVIDADE: Limiares que quebram o pipeline se a performance degradar
  thresholds: {
    http_req_duration: ['p(95)<500'], // 95% das requisições devem ser mais rápidas que 500ms
    http_req_failed: ['rate<0.01'],   // A taxa de erro (status 500, timeout) deve ser menor que 1%
  },
};

export default function () {
  const res = http.get('http://servico-podinfo.prod-apps.svc.cluster.local:9898/');

  // NOVIDADE: Asserções que vão popular os painéis de "Checks" e "Errors" no Grafana
  check(res, {
    'status is 200': (r) => r.status === 200,
    'latency is under 200ms': (r) => r.timings.duration < 200,
  });
}