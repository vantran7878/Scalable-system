#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# setup-replication.sh
# Run ONCE after "docker compose up -d" to link the slave to the master.
# ─────────────────────────────────────────────────────────────────────────────
set -e

MASTER_ROOT_PASS="rootpassword"
SLAVE_ROOT_PASS="rootpassword"
REPL_USER="replicator"
REPL_PASS="replpassword"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  MySQL Master-Slave Replication Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Wait for master ────────────────────────────────────────────────────────
echo ""
echo "▸ Waiting for mysql_master to be ready…"
until docker exec mysql_master mysqladmin ping -h localhost -u root -p"${MASTER_ROOT_PASS}" --silent 2>/dev/null; do
  printf "  ."
  sleep 2
done
echo ""
echo "  ✅ mysql_master is up."

# ── 2. Wait for slave ─────────────────────────────────────────────────────────
echo ""
echo "▸ Waiting for mysql_slave to be ready…"
until docker exec mysql_slave mysqladmin ping -h localhost -u root -p"${SLAVE_ROOT_PASS}" --silent 2>/dev/null; do
  printf "  ."
  sleep 2
done
echo ""
echo "  ✅ mysql_slave is up."

# ── 3. Get current master binlog position ─────────────────────────────────────
echo ""
echo "▸ Reading master binary log status…"
MASTER_STATUS=$(docker exec mysql_master mysql -u root -p"${MASTER_ROOT_PASS}" \
    -e "SHOW MASTER STATUS\G" 2>/dev/null)

MASTER_LOG_FILE=$(echo "${MASTER_STATUS}" | grep "File:"     | awk '{print $2}')
MASTER_LOG_POS=$( echo "${MASTER_STATUS}" | grep "Position:" | awk '{print $2}')

echo "  Log file : ${MASTER_LOG_FILE}"
echo "  Position : ${MASTER_LOG_POS}"

if [ -z "${MASTER_LOG_FILE}" ]; then
  echo ""
  echo "❌ Could not read master status. Make sure binary logging is enabled."
  exit 1
fi

# ── 4. Configure slave ────────────────────────────────────────────────────────
echo ""
echo "▸ Configuring replication on slave…"
docker exec mysql_slave mysql -u root -p"${SLAVE_ROOT_PASS}" 2>/dev/null <<EOF
STOP SLAVE;

CHANGE MASTER TO
  MASTER_HOST     = 'mysql_master',
  MASTER_USER     = '${REPL_USER}',
  MASTER_PASSWORD = '${REPL_PASS}',
  MASTER_LOG_FILE = '${MASTER_LOG_FILE}',
  MASTER_LOG_POS  =  ${MASTER_LOG_POS},
  MASTER_CONNECT_RETRY = 10,
  GET_MASTER_PUBLIC_KEY = 1;

START SLAVE;
EOF

echo "  ✅ Slave configured and started."

# ── 5. Verify ─────────────────────────────────────────────────────────────────
echo ""
echo "▸ Checking slave status…"
sleep 3   # give it a moment to connect

SLAVE_STATUS=$(docker exec mysql_slave mysql -u root -p"${SLAVE_ROOT_PASS}" \
    -e "SHOW SLAVE STATUS\G" 2>/dev/null)

IO_RUNNING=$( echo "${SLAVE_STATUS}" | grep "Slave_IO_Running:"  | awk '{print $2}')
SQL_RUNNING=$(echo "${SLAVE_STATUS}" | grep "Slave_SQL_Running:" | awk '{print $2}')
ERROR=$(      echo "${SLAVE_STATUS}" | grep "Last_Error:"        | awk '{$1=""; print $0}' | xargs)

echo "  Slave_IO_Running  : ${IO_RUNNING}"
echo "  Slave_SQL_Running : ${SQL_RUNNING}"

if [ "${IO_RUNNING}" = "Yes" ] && [ "${SQL_RUNNING}" = "Yes" ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ✅ Replication is ACTIVE — slave is in sync."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
  echo ""
  echo "⚠️  Replication may not be running correctly."
  if [ -n "${ERROR}" ]; then
    echo "  Last error: ${ERROR}"
  fi
  echo "  Run: docker exec mysql_slave mysql -u root -prootpassword -e \"SHOW SLAVE STATUS\\G\""
fi
echo ""
