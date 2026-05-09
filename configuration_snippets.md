# Configuration Snippets

This document contains key configuration settings for the Nginx load balancer, MySQL replication, and the API's database connection logic.

## 1. Nginx Load Balancer

The Nginx configuration defines an upstream pool of two API nodes (`node_a` and `node_b`) and proxies all traffic to them using a default Round Robin strategy.

### `nginx/nginx.conf`
```nginx
events {
    worker_connections 1024;
}

http {
    # ── Upstream: 2 API nodes (Round Robin by default) ──────────────────────
    upstream api_nodes {
        server node_a:3000 max_fails=3 fail_timeout=10s;
        server node_b:3000 max_fails=3 fail_timeout=10s;
    }

    server {
        listen 80;

        # ── Proxy all requests to the API node pool ──────────────────────────
        location / {
            proxy_pass         http://api_nodes;
            proxy_http_version 1.1;

            proxy_set_header   Host              $host;
            proxy_set_header   X-Real-IP         $remote_addr;
            proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header   Connection        "";

            proxy_connect_timeout 5s;
            proxy_read_timeout    30s;
            proxy_send_timeout    30s;

            # Retry on failure so one downed node is transparent to the client
            proxy_next_upstream error timeout http_502 http_503;
        }
    }
}
```

---

## 2. MySQL Database Replication

The system uses a Master-Slave replication setup. The Master handles writes, while the Slave is configured as a read-only replica.

### Master Configuration (`mysql/master/my.cnf`)
The master is assigned `server-id = 1` and has binary logging enabled to allow the slave to replicate changes.
```ini
[mysqld]
# ── Replication identity ─────────────────────────────────────────────────────
server-id          = 1

# ── Binary log (required for replication) ───────────────────────────────────
log_bin            = mysql-bin
binlog_format      = ROW
binlog_do_db       = productsdb
expire_logs_days   = 3

# ── Performance ──────────────────────────────────────────────────────────────
innodb_flush_log_at_trx_commit = 1
sync_binlog                    = 1
```

### Slave Configuration (`mysql/slave/my.cnf`)
The slave is assigned `server-id = 2`, has `read_only` enabled to prevent accidental writes, and uses a relay log to receive events from the master.
```ini
[mysqld]
# ── Replication identity ─────────────────────────────────────────────────────
server-id  = 2

# ── Relay log (receives events from master) ──────────────────────────────────
relay-log  = relay-bin

# ── Prevent accidental writes to the replica ────────────────────────────────
read_only  = 1

# ── Make replication survive restarts ────────────────────────────────────────
relay_log_recovery = 1
```

---

## 3. Database Schema and Initialization

The master database initializes the `productsdb` database, creates the `products` table, and sets up users for both the application and the replication process.

### `mysql/master/init/01-init.sql`
```sql
CREATE DATABASE IF NOT EXISTS productsdb;
USE productsdb;

CREATE TABLE IF NOT EXISTS products (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    name       VARCHAR(255)   NOT NULL,
    price      DECIMAL(10, 2) NOT NULL,
    created_at TIMESTAMP      DEFAULT CURRENT_TIMESTAMP
);

-- Application user (read + write on master)
CREATE USER IF NOT EXISTS 'appuser'@'%' IDENTIFIED BY 'apppassword';
GRANT ALL PRIVILEGES ON productsdb.* TO 'appuser'@'%';

-- Replication user
CREATE USER IF NOT EXISTS 'replicator'@'%'
    IDENTIFIED WITH mysql_native_password BY 'replpassword';
GRANT REPLICATION SLAVE   ON *.* TO 'replicator'@'%';
GRANT REPLICATION CLIENT  ON *.* TO 'replicator'@'%';

FLUSH PRIVILEGES;
```

---

## 4. API Database Connection Logic

The API is built with Node.js/Express and uses the `mysql2` library to manage separate connection pools for the Master (writes) and Slave (reads).

### `api/index.js` (Connection Pools)
```javascript
const masterPool = mysql.createPool({
  host:             process.env.DB_MASTER_HOST || "localhost",
  user:             process.env.DB_USER,
  password:         process.env.DB_PASSWORD,
  database:         process.env.DB_NAME,
  waitForConnections: true,
  connectionLimit:  10,
  queueLimit:       0,
});

const slavePool = mysql.createPool({
  host:             process.env.DB_SLAVE_HOST || "localhost",
  user:             process.env.DB_USER,
  password:         process.env.DB_PASSWORD,
  database:         process.env.DB_NAME,
  waitForConnections: true,
  connectionLimit:  10,
  queueLimit:       0,
});
```

### Read/Write Splitting Logic
The application explicitly routes `POST` requests to the `masterPool` and `GET` requests to the `slavePool`.

**Write Example (POST /products):**
```javascript
app.post("/products", async (req, res) => {
  // ... validation logic ...
  try {
    const [result] = await masterPool.execute(
      "INSERT INTO products (name, price) VALUES (?, ?)",
      [name, price]
    );
    // ... response ...
  } catch (err) {
    // ... error handling ...
  }
});
```

**Read Example (GET /products):**
```javascript
app.get("/products", async (req, res) => {
  try {
    const [rows] = await slavePool.execute(
      "SELECT * FROM products ORDER BY created_at DESC"
    );
    // ... response ...
  } catch (err) {
    // ... error handling ...
  }
});
```
