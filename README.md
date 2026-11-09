# Infrastructure

Docker Compose stack for the InnoBoard microservice system: API Gateway, Auth Service
(Postgres + RSA keys), User Service (Postgres + Redis) and Order Service (Postgres +
Redis). Lives in a dedicated repository, separate from the services it launches.

The stack builds images from the sibling repositories — clone this repo next to them:

```
AdvanceCourses/
├── api-gateway/
├── auth-service/
├── user-service/
├── order-service/
└── infra/         
```

## Responsibility split

| Service        | Container port | Routed by gateway   |
|----------------|----------------|---------------------|
| `api-gateway`  | **8080** (published host port) | — |
| `auth-service` | 8081           | `/api/auth/**` |
| `user-service` | 8082           | `/api/users/**`, `/api/cards/**` |
| `order-service`| 8083           | `/api/orders/**`, `/api/items/**` |

Only the gateway publishes a host port; all databases and Redis stay on the internal
Docker network (`innoboard-internal`).

## Configuration

Credentials for the whole stack (database users/passwords, `JWT_KEY_ID`) are read from
`.env` by `docker compose` — see `.env.example`.
