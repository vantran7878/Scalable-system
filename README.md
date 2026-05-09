# Scalable System — Node.js + Nginx + MySQL Master-Slave

Repo link: [https://github.com/vantran7878/Scalable-system.git](https://github.com/vantran7878/Scalable-system.git)

Video link: [Here](https://youtu.be/8uabvUyz3es)

## Architecture

```
Client
  │
  ▼
[Nginx :80]  ←── Round Robin Load Balancer
  │     │
  ▼     ▼
[Node_A]             [Node_B]   ← Express API (port 3000 each)
  │   \             /   │
  │     \        /      │
  │       \    /        │
  |        \  /         |
  |       /   \         |
  |     /       \       |
  |   /           \     |
  | /                \  | 
  ▼  Write            Read ▼
[MySQL Master]   [MySQL Slave]
  (port 3306)      (port 3307)
       │                ▲
       └── replication ─┘
```

| Layer         | Container      | Role                         |
|---------------|----------------|------------------------------|
| Load Balancer | nginx_lb       | Distributes traffic (Round Robin strategy) |
| API           | node_a, node_b | REST API with R/W splitting  |
| DB Write      | mysql_master   | Handles POST (INSERT)        |
| DB Read       | mysql_slave    | Handles GET (SELECT)         |

---

## Prerequisites

- Docker Desktop (or Docker + Docker Compose v2)
- Port **80**, **3306**, **3307** available on machine

---

# Set up guide
## Phase 1 — Start the Containers

```bash
# Clone / unzip the project, then:
cd scalable-system

# Build and start everything
docker compose up -d --build
```

Wait ~30 seconds for MySQL to fully initialize. You can watch progress through:

```bash
docker compose logs -f mysql_master
```

Look for: `ready for connections`

---

## Phase 2 — Configure Replication (run once)

```bash
chmod +x setup-replication.sh
./setup-replication.sh
```

Expected output:
```
✅ mysql_master is up.
✅ mysql_slave is up.
Log file : mysql-bin.000003
Position : 857
✅ Slave configured and started.
Slave_IO_Running  : Yes
Slave_SQL_Running : Yes
✅ Replication is ACTIVE — slave is in sync.
```

---

## Phase 3 — Verify API & Load Balancing

### POST a product (writes to Master)

Using `curl` or `Postman` to test route and API calling

```bash
curl -s -X POST http://localhost/products \
  -H "Content-Type: application/json" \
  -d '{"name":"Laptop","price":999.99}' | jq
```

You can use `Postman` to test a `POST` request with ``http://localhost/products`` together with a `JSON` body.

Response only from master database:
```json
{
  "message": "Product created successfully.",
  "data": { "id": 1, "name": "Laptop", "price": 999.99 },
  "processed_by": "Node_A",
  "db_target": "master"
}
```

### GET products (reads from Slave) — run multiple times. 
You can also test it through `GET` request from `Postman` through ``http://localhost/products`` many times

```bash
for i in {1..4}; do
  curl -s http://localhost/products | jq '{processed_by, db_target}'
done
```

Watch **processed_by** alternate between `Node_A` and `Node_B` → load balancer is working.

### Health check

```bash
curl http://localhost/health
```

---

## Phase 4 — Chaos Test (Fault Tolerance)

Shut down one API node and confirm traffic keeps flowing:

```bash
# Kill Node A
docker stop node_a

# All requests now go to Node B
for i in {1..4}; do
  curl -s http://localhost/products | jq '.processed_by'
done
# → all "Node_B"

# Bring Node A back
docker start node_a
```

---

## Verify Replication Directly

```bash
# Insert via master
docker exec mysql_master mysql -u appuser -papppassword productsdb \
  -e "INSERT INTO products (name, price) VALUES ('Test Item', 9.99);"

# Read from slave
docker exec mysql_slave mysql -u appuser -papppassword productsdb \
  -e "SELECT * FROM products;"
```

---

## Useful Commands

```bash
# Watch all logs
docker compose logs -f

# Check slave replication health
docker exec mysql_slave mysql -u root -prootpassword \
  -e "SHOW SLAVE STATUS\G" | grep -E "Running|Error|Behind"

# Tear down and remove volumes (fresh start)
docker compose down -v
```

---

## Read/Write Splitting (Code)

In `api/index.js`:

```js
// WRITE → Master
const [result] = await masterPool.execute(
  "INSERT INTO products (name, price) VALUES (?, ?)",
  [name, price]
);

// READ → Slave
const [rows] = await slavePool.execute(
  "SELECT * FROM products ORDER BY created_at DESC"
);
```

Two separate connection pools point to different hosts via environment variables:
- `DB_MASTER_HOST=mysql_master`
- `DB_SLAVE_HOST=mysql_slave`
