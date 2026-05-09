-- ── Master initialization ────────────────────────────────────────────────────

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

-- Replication user (must use mysql_native_password for slave compatibility)
CREATE USER IF NOT EXISTS 'replicator'@'%'
    IDENTIFIED WITH mysql_native_password BY 'replpassword';
GRANT REPLICATION SLAVE   ON *.* TO 'replicator'@'%';
GRANT REPLICATION CLIENT  ON *.* TO 'replicator'@'%';

FLUSH PRIVILEGES;
