#!/usr/bin/env bash
set -euo pipefail

echo "==> Pods"
kubectl -n innoboard get pods -o wide

echo
echo "==> Проверка Service discovery из pod'а api-gateway"
for target in "auth-service:8081" "user-service:8082" "order-service:8083" "payment-service:8084"; do
  name="${target%%:*}"
  port="${target##*:}"
  url="http://${name}:${port}/actuator/health"
  echo -n "$url -> "
  kubectl -n innoboard exec deploy/api-gateway -- curl -fsS "$url"
  echo
done

echo -n "http://localhost:8080/actuator/health (gateway) -> "
kubectl -n innoboard exec deploy/api-gateway -- curl -fsS http://localhost:8080/actuator/health
echo

echo
echo "==> StatefulSet / Deployment rollout"
kubectl -n innoboard get statefulsets,deployments

echo
echo "==> Ingress"
kubectl -n innoboard get ingress

echo
echo "Если ADDRESS пустой — запустите в отдельном терминале: minikube -p innoboard tunnel"
echo "Проверка через ingress:"
echo "  curl --resolve innoboard.local:80:127.0.0.1 http://innoboard.local/actuator/health"
