-- ── Slave initialization ─────────────────────────────────────────────────────
-- Creates schema & app user so the API can connect on startup.
-- The replication setup script will configure the link to the master.

CREATE DATABASE IF NOT EXISTS productsdb;
USE productsdb;

CREATE TABLE IF NOT EXISTS products (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    name       VARCHAR(255)   NOT NULL,
    price      DECIMAL(10, 2) NOT NULL,
    created_at TIMESTAMP      DEFAULT CURRENT_TIMESTAMP
);

-- App user with read-only access (slave has read_only=1 anyway)
CREATE USER IF NOT EXISTS 'appuser'@'%' IDENTIFIED BY 'apppassword';
GRANT SELECT ON productsdb.* TO 'appuser'@'%';

FLUSH PRIVILEGES;
