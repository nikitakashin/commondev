import { randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";

// stdout is a private control pipe consumed by the parent, never a log stream.
for (const name of ["log", "info", "warn", "error", "debug"]) {
  console[name] = (...args) => process.stderr.write(args.map(String).join(" ") + "\n");
}

const dataDirectory = process.argv[2];
if (!dataDirectory || !path.isAbsolute(dataDirectory)) {
  throw new Error("An absolute data directory is required");
}
mkdirSync(dataDirectory, { recursive: true, mode: 0o700 });
const keyPath = path.join(dataDirectory, "encryption-key");
let encryptionKey;
try {
  encryptionKey = readFileSync(keyPath, "utf8").trim();
} catch (error) {
  if (error.code !== "ENOENT") throw error;
  const generated = randomBytes(32).toString("hex");
  try {
    writeFileSync(keyPath, generated, { mode: 0o600, flag: "wx" });
    encryptionKey = generated;
  } catch (writeError) {
    if (writeError.code !== "EEXIST") throw writeError;
    encryptionKey = readFileSync(keyPath, "utf8").trim();
  }
}
if (!/^[a-f0-9]{64}$/.test(encryptionKey)) throw new Error("Invalid gateway encryption key");
process.env.ENCRYPTION_KEY = encryptionKey;
process.env.NODE_ENV = "production";
process.env.FREEAPI_DB_PATH = path.join(dataDirectory, "freeapi.db");

const { startServer, getUnifiedApiKey, getDb } = await import("./server.mjs");
const { server } = await startServer({
  dbPath: process.env.FREEAPI_DB_PATH,
  clientDist: path.join(dataDirectory, "no-web-ui"),
  host: "127.0.0.1",
  preferredPort: 0,
});
const address = server.address();
if (!address || typeof address === "string") throw new Error("Gateway did not bind a TCP port");
const shutdown = () => server.close(() => process.exit(0));
process.once("SIGTERM", shutdown);
process.once("SIGINT", shutdown);
process.stdin.resume();
process.stdin.once("end", shutdown);

// A listening socket is available before the first catalog sync has enabled
// the keyless providers.  Do not expose readiness until at least one enabled
// provider has a tools-capable model in the installed catalog.
const db = getDb();
const hasToolsProvider = db.prepare(`
  SELECT EXISTS (
    SELECT 1 FROM models m
    JOIN api_keys k ON k.platform = m.platform
    WHERE m.enabled = 1 AND m.supports_tools = 1 AND k.enabled = 1
  ) AS ready
`);
const deadline = Date.now() + 60_000;
while (!hasToolsProvider.get().ready && Date.now() < deadline) {
  await new Promise(resolve => setTimeout(resolve, 500));
}
if (!hasToolsProvider.get().ready) {
  process.stdout.write(JSON.stringify({
    type: "error",
    message: "Не удалось подготовить бесплатные модели. Проверьте подключение к интернету и попробуйте снова.",
  }) + "\n");
  server.close(() => process.exit(1));
  setTimeout(() => process.exit(1), 1000).unref();
} else {
  process.stdout.write(JSON.stringify({
    type: "ready",
    port: address.port,
    token: getUnifiedApiKey(),
  }) + "\n");
}
