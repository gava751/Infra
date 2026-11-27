#!/usr/bin/env bash
set -euo pipefail

K8S_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$K8S_DIR/.." && pwd)"
REPO_ROOT="$(cd "$INFRA_DIR/.." && pwd)"

PROFILE="${PROFILE:-innoboard}"
CPUS="${CPUS:-4}"
MEMORY="${MEMORY:-8192mb}"
DISK_SIZE="${DISK_SIZE:-20g}"
SKIP_BUILD="${SKIP_BUILD:-0}"

if ! command -v minikube >/dev/null 2>&1; then
  echo "minikube не найден. Установите его: https://minikube.sigs.k8s.io/docs/start/" >&2
  exit 1
fi
if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl не найден в PATH." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker не запущен. Запустите Docker Desktop (или Docker daemon) и повторите." >&2
  exit 1
fi

echo "==> Запуск Minikube (profile=$PROFILE, cpus=$CPUS, memory=$MEMORY)"
minikube -p "$PROFILE" start --driver=docker --cpus="$CPUS" --memory="$MEMORY" --disk-size="$DISK_SIZE"

echo "==> Включение ingress addon"
minikube -p "$PROFILE" addons enable ingress

if [[ "$SKIP_BUILD" != "1" ]]; then
  for service in api-gateway auth-service user-service order-service payment-service; do
    image="innoboard/${service}:latest"
    context="$REPO_ROOT/$service"
    echo "==> Сборка $image"
    if ! minikube -p "$PROFILE" image build -t "$image" "$context"; then
      echo "minikube image build не удался для $service, пробую docker build + minikube image load" >&2
      docker build -t "$image" "$context"
      minikube -p "$PROFILE" image load "$image"
    fi
  done
fi

echo "==> Подготовка секретов и JWT-ключей"
"$K8S_DIR/prepare.sh"

echo "==> Применение манифестов"
kubectl apply -k "$K8S_DIR"

echo "==> Ожидание базы данных и Kafka"
for name in auth-postgres user-postgres order-postgres payment-mongo kafka; do
  kubectl -n innoboard rollout status "statefulset/$name" --timeout=600s
done

echo "==> Ожидание приложений"
for name in user-redis order-redis auth-service user-service order-service payment-service api-gateway; do
  kubectl -n innoboard rollout status "deployment/$name" --timeout=600s
done

kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=300s || true

echo
echo "==> Состояние кластера"
kubectl -n innoboard get pods,svc,ingress

echo
echo "Готово. Доступ снаружи (в отдельном терминале):"
echo "  kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80"
echo "  curl -H 'Host: innoboard.local' http://localhost:8080/actuator/health"
echo
echo "Альтернатива: minikube -p $PROFILE service -n ingress-nginx ingress-nginx-controller --url"
echo "(печатает локальный адрес; запросы всё равно нужно слать с заголовком Host: innoboard.local)"
