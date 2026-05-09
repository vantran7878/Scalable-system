const express = require("express");
const mysql   = require("mysql2/promise");

const app     = express();
const NODE_ID = process.env.NODE_ID   || "Node_Unknown";
const PORT    = process.env.PORT      || 3000;

app.use(express.json());

// ── Connection pools ─────────────────────────────────────────────────────────

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

// ── Wait for DB helper (retries until container is ready) ─────────────────────

async function waitForDb(pool, label, maxRetries = 30, delayMs = 3000) {
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      const conn = await pool.getConnection();
      await conn.query("SELECT 1");
      conn.release();
      console.log(`[${NODE_ID}] ✅ Connected to ${label}`);
      return;
    } catch (err) {
      console.log(`[${NODE_ID}] ⏳ Waiting for ${label} (attempt ${attempt}/${maxRetries})…`);
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
  throw new Error(`[${NODE_ID}] ❌ Could not connect to ${label} after ${maxRetries} attempts`);
}

// ── Routes ───────────────────────────────────────────────────────────────────

/**
 * POST /products
 * Writes to the MASTER database.
 */
app.post("/products", async (req, res) => {
  const { name, price } = req.body;

  if (!name || price === undefined) {
    return res.status(400).json({ error: "Both 'name' and 'price' are required." });
  }
  if (typeof price !== "number" || price < 0) {
    return res.status(400).json({ error: "'price' must be a non-negative number." });
  }

  try {
    const [result] = await masterPool.execute(
      "INSERT INTO products (name, price) VALUES (?, ?)",
      [name, price]
    );
    return res.status(201).json({
      message:      "Product created successfully.",
      data:         { id: result.insertId, name, price },
      processed_by: NODE_ID,
      db_target:    "master",
    });
  } catch (err) {
    console.error(`[${NODE_ID}] Write error:`, err.message);
    return res.status(500).json({ error: "Database write failed.", detail: err.message });
  }
});

/**
 * GET /products
 * Reads from the SLAVE (read-replica) database.
 */
app.get("/products", async (req, res) => {
  try {
    const [rows] = await slavePool.execute(
      "SELECT * FROM products ORDER BY created_at DESC"
    );
    return res.json({
      data:         rows,
      count:        rows.length,
      processed_by: NODE_ID,
      db_target:    "slave",
    });
  } catch (err) {
    console.error(`[${NODE_ID}] Read error:`, err.message);
    return res.status(500).json({ error: "Database read failed.", detail: err.message });
  }
});

/**
 * GET /health
 * Used by the load balancer / chaos test to check liveness.
 */
app.get("/health", (_req, res) => {
  res.json({ status: "ok", node: NODE_ID });
});



(async () => {
  try {
    await waitForDb(masterPool, "MySQL Master");
    await waitForDb(slavePool,  "MySQL Slave");
    app.listen(PORT, () => {
      console.log(`[${NODE_ID}] 🚀 Server listening on port ${PORT}`);
    });
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }
})();
