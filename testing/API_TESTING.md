# API Testing Guide (curl commands)

All endpoints are under the backend API. Adjust `BASE_URL` depending on your environment.

## Environment Setup

```bash
# Docker Compose
BASE_URL="http://localhost:5000/api"

# Kubernetes (port-forward or ingress)
BASE_URL="http://localhost:9090/api"
```

---

## Health Check

```bash
curl -s $BASE_URL/health | jq
```

Expected response:
```json
{ "status": "OK", "message": "Server is running" }
```

---

## Users CRUD

### Get All Users

```bash
curl -s $BASE_URL/users | jq
```

### Get User by ID

```bash
curl -s $BASE_URL/users/1 | jq
```

404 case (non-existent user):
```bash
curl -s -w "\nHTTP Status: %{http_code}\n" $BASE_URL/users/9999 | jq
```

### Create a User

```bash
curl -s -X POST $BASE_URL/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice Johnson", "email": "alice@example.com"}' | jq
```

Duplicate email (expects 409):
```bash
curl -s -w "\nHTTP Status: %{http_code}\n" -X POST $BASE_URL/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice Again", "email": "alice@example.com"}'
```

Missing fields (expects 400):
```bash
curl -s -w "\nHTTP Status: %{http_code}\n" -X POST $BASE_URL/users \
  -H "Content-Type: application/json" \
  -d '{"name": "No Email"}'
```

### Update a User

```bash
curl -s -X PUT $BASE_URL/users/1 \
  -H "Content-Type: application/json" \
  -d '{"name": "John Updated", "email": "john.updated@example.com"}' | jq
```

Update non-existent user (expects 404):
```bash
curl -s -w "\nHTTP Status: %{http_code}\n" -X PUT $BASE_URL/users/9999 \
  -H "Content-Type: application/json" \
  -d '{"name": "Ghost", "email": "ghost@example.com"}'
```

### Delete a User

```bash
curl -s -X DELETE $BASE_URL/users/1 | jq
```

Delete non-existent user (expects 404):
```bash
curl -s -w "\nHTTP Status: %{http_code}\n" -X DELETE $BASE_URL/users/9999
```

---

## Full CRUD Workflow (copy-paste)

Run this block to exercise the entire lifecycle:

```bash
BASE_URL="http://localhost:5000/api"

echo "=== Health Check ==="
curl -s $BASE_URL/health | jq

echo -e "\n=== List Users (initial) ==="
curl -s $BASE_URL/users | jq

echo -e "\n=== Create User ==="
curl -s -X POST $BASE_URL/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Test User", "email": "test@example.com"}' | jq

echo -e "\n=== List Users (after create) ==="
curl -s $BASE_URL/users | jq

echo -e "\n=== Get User by ID ==="
USER_ID=$(curl -s $BASE_URL/users | jq -r '.[-1].id')
curl -s $BASE_URL/users/$USER_ID | jq

echo -e "\n=== Update User ==="
curl -s -X PUT $BASE_URL/users/$USER_ID \
  -H "Content-Type: application/json" \
  -d '{"name": "Updated User", "email": "updated@example.com"}' | jq

echo -e "\n=== Delete User ==="
curl -s -X DELETE $BASE_URL/users/$USER_ID | jq

echo -e "\n=== List Users (after delete) ==="
curl -s $BASE_URL/users | jq
```

---

## Load Testing (quick burst)

Send 50 rapid requests to the health endpoint:

```bash
for i in $(seq 1 50); do
  curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" $BASE_URL/health &
done
wait
```

Send 20 concurrent POST requests (useful for triggering HPA):

```bash
for i in $(seq 1 20); do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST $BASE_URL/users \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"Load User $i\", \"email\": \"load${i}@example.com\"}" &
done
wait
```
