# InnoBoard — инфраструктура (docker compose + Kubernetes)

Инфраструктурный репозиторий системы InnoBoard: master docker compose и манифесты
Kubernetes (Minikube) для всего стека. Сами сервисы живут в соседних репозиториях —
склонируйте их рядом:

```
AdvanceCourses/
├── api-gateway/      Spring Cloud Gateway (WebFlux), проверка JWT по JWKS auth-service
├── auth-service/     регистрация/логин, RS256-токены, PostgreSQL
├── user-service/     профили и карты, Redis-кэш, OAuth2 Resource Server
├── order-service/    заказы и товары, Kafka consumer, Redis
├── payment-service/  платежи, MongoDB, Kafka producer
└── infra/            этот репозиторий
```

## Общая архитектура системы

```
снаружи ──► [k8s] Ingress innoboard.local ──► api-gateway :8080 ◄── единственная точка входа
             [compose] localhost:8080            (публикует порт только он)

                /api/auth/**      ──► auth-service    :8081
                /api/users/**     ──► user-service    :8082
                /api/cards/**     ──► user-service    :8082
                /api/orders/**    ──► order-service   :8083
                /api/items/**     ──► order-service   :8083
                /api/payments/**  ──► payment-service :8084

межсервисные HTTP-вызовы (через Service DNS, заголовок X-Internal-Token):
    auth-service    ─► user-service  /internal/users   создание профиля при register, компенсация
    order-service   ─► user-service  валидация владельца заказа
    payment-service ─► user-service  userEmail → userId (resolved server-side)

события (Kafka, топик payment-events):
    payment-service (producer) ─► kafka :9092 ─► order-service (consumer)

данные и кэши:
    auth-service    ─► auth-postgres  :5432
    user-service    ─► user-postgres  :5432 + user-redis  :6379
    order-service   ─► order-postgres :5432 + order-redis :6379
    payment-service ─► payment-mongo  :27017
```

- **JWT:** auth-service подписывает токены RS256, приватный ключ есть только у него.
  Gateway и ресурсные сервисы проверяют подпись локально по `/.well-known/jwks.json`
  auth-service — никакой публичной интроспекции токенов нет.
- **Идентификатор владельца не приходит от клиента:** register/login принимают логин и
  пароль, userId синхронно резолвится вызовом user-service; payment принимает email,
  userId тоже resolved server-side.
- **Наружу публикует только точка входа:** в compose `ports` есть только у gateway;
  в k8s все Service — ClusterIP/headless, снаружи только Ingress.
- Имена зависимостей (БД, Redis, Kafka) совпадают в обеих средах
  (`auth-postgres`, `user-redis`, `kafka`, …); адреса самих сервисов подставляются
  через переменные окружения (в compose — `*-app` суффикс, в k8s — имя Service).

## Содержимое репозитория

```
infra/
├── docker-compose.yml     master-compose полного стека (5 сервисов + 3 PostgreSQL
│                          + MongoDB + 2 Redis + Kafka KRaft), healthcheck у каждого,
│                          depends_on condition: service_healthy
├── .env.example           шаблон переменных; копируется в .env (git-ignored)
├── .gitignore             игнорирует .env, k8s/secrets.env, k8s/keys/*.pem
└── k8s/
    ├── kustomization.yaml точка входа: kubectl apply -k infra/k8s
    ├── namespace.yaml     namespace innoboard
    ├── config.yaml        ConfigMap'ы с не-секретной конфигурацией 5 сервисов
    ├── ingress.yaml       Ingress innoboard.local → api-gateway:8080
    ├── secrets.env        генерируется prepare-скриптом из ../.env (git-ignored)
    ├── keys/              JWT-ключи, копируются из auth-service/keys (git-ignored)
    ├── infrastructure/    postgres.yaml (3× StatefulSet), mongo.yaml, redis.yaml (2×),
    │                      kafka.yaml (KRaft)
    ├── apps/              Service + Deployment каждого из 5 сервисов
    ├── prepare.ps1 / .sh  генерация secrets.env и копирование JWT-ключей
    ├── deploy.ps1 / .sh   minikube start + ingress addon + сборка образов + apply + rollout-wait
    └── verify.ps1 / .sh   проверка подов, service discovery, ingress
```

## Запуск: docker compose

Требуется запущенный Docker, соседние репозитории сервисов и два файла вне git:

1. **RSA-ключи** `../auth-service/keys/jwt-{private,public}.pem` — генерируются один раз
   (инструкция в `auth-service/README.md`):

   ```bash
   mkdir -p ../auth-service/keys
   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
     -out ../auth-service/keys/jwt-private.pem
   openssl pkey -in ../auth-service/keys/jwt-private.pem -pubout \
     -out ../auth-service/keys/jwt-public.pem
   ```

2. **`.env`** — скопировать `.env.example` и заменить пароли `change-me`.
   Compose не стартует без него (обязательные переменные — `${VAR:?...}`).

```bash
cp .env.example .env
docker compose up -d --build
```

После старта система доступна на `http://localhost:8080` (gateway). Базы, Redis и
Kafka портов наружу не публикуют — только внутренняя сеть `innoboard-internal` и
healthcheck'и (`$$VAR` из окружения контейнера, без литеральных кредов).

## Запуск: Kubernetes (Minikube)

Требования: Docker Desktop запущен, `kubectl`, `minikube`, минимум 8 ГБ RAM для
кластера (`--memory=8192mb --cpus=4`), заполненный `infra/.env`, JWT-ключи в
`auth-service/keys/`.

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\k8s\deploy.ps1
# повторный запуск без пересборки образов:
.\k8s\deploy.ps1 -SkipBuild
```

Linux/macOS:

```bash
./k8s/deploy.sh          # или SKIP_BUILD=1 ./k8s/deploy.sh
```

Скрипт делает всё сам: поднимает Minikube (`profile=innoboard`), включает ingress
addon, собирает 5 образов (`minikube image build`, fallback — docker build + image
load), готовит `secrets.env` и ключи (`prepare`), применяет `kubectl apply -k`,
ждёт rollout всех StatefulSet и Deployment и печатает состояние кластера.

Обновление после изменения кода:

```powershell
minikube -p innoboard image build -t innoboard/user-service:latest ..\user-service
kubectl -n innoboard rollout restart deployment/user-service
```

Удаление: `kubectl delete -k .\k8s` или `minikube -p innoboard delete`
(PVC удаляются вместе с namespace — данные БД пропадут).

### Доступ снаружи

Ingress маршрутизирует по домену `innoboard.local` и ведёт на `api-gateway:8080`.
Заголовок `Host` обязателен.

```powershell
# отдельный терминал
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80

curl.exe -H "Host: innoboard.local" http://localhost:8080/actuator/health
# {"groups":["liveness","readiness"],"status":"UP"}
```

Альтернатива: `minikube -p innoboard service -n ingress-nginx ingress-nginx-controller --url`
(держит tunnel открытым; заголовок `Host` всё равно нужен).

Почему не «просто http://innoboard.local»: при драйвере docker на Windows узел
Minikube живёт в отдельной сети (`192.168.49.2`), хост туда не маршрутизирует.
Ingress-аддон публикует контроллер как **NodePort** (`80:30503`), а не LoadBalancer,
поэтому `minikube tunnel` доступ к Ingress не даёт (tunnel работает только с
LoadBalancer-сервисами). Port-forward — проверенный путь без прав администратора.

## Probes

У всех приложений и инфраструктурных компонентов настроены startup, readiness и
liveness пробы.

### Spring Boot сервисы

| Probe    | Path                        | Период | Порог | Смысл                                     |
|----------|-----------------------------|--------|-------|-------------------------------------------|
| startup  | `/actuator/health/liveness` | 5s     | 60    | дать JVM время на старт (до 5 минут)      |
| readiness| `/actuator/health/readiness`| 5s     | 3     | не слать трафик, пока приложение не готово|
| liveness | `/actuator/health/liveness` | 10s    | 3     | перезапустить зависший процесс            |

Пробы включены в `application.yml` всех сервисов
(`management.endpoint.health.probes.enabled: true`). Эндпоинты `/actuator/health/**`
разрешены в security-конфигурациях gateway, auth-service и user-service;
order-service и payment-service Spring Security не используют.

### Инфраструктура

| Компонент  | Liveness / Readiness                              | Startup                    |
|------------|---------------------------------------------------|----------------------------|
| PostgreSQL | `pg_isready -U $POSTGRES_USER -d $POSTGRES_DB`    | то же, 60×5s               |
| MongoDB    | `mongosh … db.adminCommand({ping:1}).ok`          | то же, 60×5s               |
| Redis      | `redis-cli ping`                                  | то же, 30×3s               |
| Kafka      | readiness: `kafka-broker-api-versions.sh`; liveness: TCP 9092 | то же, 40×15s   |

## Конфигурация и секреты

### ConfigMap'ы (`k8s/config.yaml`)

- `api-gateway-config` — URL'ы всех бэкендов;
- `auth-service-config` — `USER_SERVICE_URL`, пути к JWT-ключам, TTL;
- `user-service-config` — `AUTH_SERVICE_URL`, Redis;
- `order-service-config` — `USER_SERVICE_URL`, Redis, Kafka, топик;
- `payment-service-config` — `USER_SERVICE_URL`, Kafka, топик, random.org URL.

Во всех сервисах включён профиль `docker` и `SERVER_SHUTDOWN=graceful`.

### Secret `innoboard-secrets`

Генерируется Kustomize из `k8s/secrets.env`, который создаёт prepare-скрипт из
`infra/.env`: креды трёх PostgreSQL и MongoDB, `INTERNAL_SERVICE_TOKEN`,
`JWT_KEY_ID` и производные `AUTH_DB_URL` / `USER_DB_URL` / `ORDER_DB_URL` /
`PAYMENT_MONGO_URI` с in-cluster hostnames.

### Secret `jwt-keys`

Собирается Kustomize из `k8s/keys/jwt-{private,public}.pem`, монтируется в
auth-service в `/app/keys` read-only с `defaultMode: 0444`.

Секреты в git не попадают: `.gitignore` закрывает `.env`, `k8s/secrets.env`,
`k8s/keys/*.pem`; отсутствующая конфигурация роняет приложение на старте
(плейсхолдеры без дефолтов, `${VAR:?}` в compose).

## Проверка стенда

Быстрая проверка: `powershell -ExecutionPolicy Bypass -File .\k8s\verify.ps1`
(или `./k8s/verify.sh`): поды, health всех бэкендов из пода gateway, rollout,
Ingress через port-forward.

Ожидаемое состояние: 12 подов `Running 1/1` (5 сервисов + 3 PostgreSQL + Mongo +
2 Redis + Kafka), 5 PVC `Bound`, Ingress с адресом.

Стенд проверен полностью, включая холодный перезапуск кластера:

| Проверка | Результат |
|---|---|
| 12 подов после перезапуска Docker | `Running 1/1 Ready`, восстановились через пробы |
| 5 PVC | `Bound` |
| liveness/readiness всех 5 сервисов | `200`, `{"status":"UP"}` |
| health бэкендов из пода gateway (Service DNS) | все `UP` |
| Ingress: `Host: innoboard.local` | `200` |
| Ingress: чужой или пустой `Host` | `404` от ingress-nginx |
| `POST /api/auth/register` | `201`, профиль создаётся в user-service |
| `POST /api/auth/login` | `200`, RS256 access/refresh |
| `GET /api/auth/me`, `GET /api/users/{id}` через gateway | `200` |
| `POST /api/payments` | `201` `IN_PROGRESS`, финализация @Async + random.org → `SUCCESS` в Mongo |
| Kafka | топик `payment-events`, consumer group `order-service`, lag 0 |

## Troubleshooting

| Симптом | Что проверить |
|---|---|
| Под в `Init:0/1` | ждёт зависимость: `kubectl -n innoboard logs <pod> -c wait-for-dependencies` (у gateway — `-c wait-for-backends`); проверьте, что соответствующий Service и под Ready |
| Поды `Unknown` после перезапуска Docker | норма: kubelet восстанавливает контейнеры за 1–2 минуты; зависшие — `kubectl -n innoboard rollout restart deployment/<name>` |
| `CrashLoopBackOff` у auth-service | секрет смонтирован? `kubectl -n innoboard get secret jwt-keys` и `kubectl -n innoboard exec deploy/auth-service -- ls -l /app/keys` |
| `ImagePullBackOff` | образ не загружен в Minikube: `minikube -p innoboard image ls | findstr innoboard` (PowerShell) или `\| grep innoboard` (bash); пересоберите через `deploy.ps1` без `-SkipBuild` |
| Ingress отдаёт 404 | заголовок `Host: innoboard.local` обязателен; проверьте `kubectl -n innoboard get ingress` и `kubectl -n ingress-nginx get pods` |
| Ingress без ADDRESS | ADDRESS — это IP ноды (`192.168.49.2`); если пусто, контроллер не готов: `kubectl -n ingress-nginx get pods`. `minikube tunnel` для этого стенда не применяется — контроллер опубликован как NodePort (см. «Доступ снаружи») |
| Kafka не стартует | `kubectl -n innoboard logs statefulset/kafka -f`; PVC `Bound`; env `KAFKA_CONTROLLER_QUORUM_VOTERS` |
| PostgreSQL permission denied | PVC `Bound`; в манифесте `mountPath: /var/lib/postgresql/18/docker` — путь образа postgres:18, как в compose |
| Долгий первый старт | JVM + Liquibase; startupProbe даёт до 5 минут; смотрите `kubectl -n innoboard get events --sort-by=.lastTimestamp` |

## Осознанные ограничения стенда

- **Одна реплика каждого сервиса.** Причина — Liquibase-миграции при старте и
  in-memory `@Async` финализация платежей. Для масштабирования нужен отдельный
  Job/init-container для миграций и идемпотентная обработка `IN_PROGRESS`.
- **Kafka single-node KRaft** — как в compose. Для продакшена — минимум 3
  брокера/контроллера и `replication.factor >= 3`.
- **Redis без пароля и без персистентности** (`emptyDir`) — это кэш, данные
  восстанавливаются из БД.
- **JWT-ключи** монтируются из Secret с `defaultMode: 0444`; в продакшене — внешний
  secret manager (Vault, Sealed Secrets, External Secrets) и ротация.
- **Ingress без TLS.** Для продакшена — cert-manager + TLS.
- **Нет HPA, NetworkPolicy, PDB, resource quotas** — стенд учебный.
- **random.org** — внешняя зависимость payment-service; в закрытом контуре нужен
  egress или замена на внутренний сервис.
- Образы собираются с тегом `latest` и `imagePullPolicy: IfNotPresent`, чтобы
  Minikube использовал локальные образы. В CI — immutable теги (например, git SHA).
