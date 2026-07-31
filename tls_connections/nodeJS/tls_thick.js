import 'dotenv/config';
import { existsSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';
import oracledb from 'oracledb';

function resolveInstantClientHome() {
  if (process.env.ORACLE_CLIENT_HOME && existsSync(process.env.ORACLE_CLIENT_HOME)) {
    return process.env.ORACLE_CLIENT_HOME;
  }

  const home = process.env.HOME || '';
  const candidates = [
    resolve(home, 'Downloads/instantclient_23_26'),
    resolve(home, 'Downloads/instantclient_23_8'),
    '/opt/homebrew/lib/instantclient',
  ];

  const downloadsDir = resolve(home, 'Downloads');
  if (existsSync(downloadsDir)) {
    const matched = readdirSync(downloadsDir)
      .filter((name) => name.startsWith('instantclient_'))
      .sort()
      .reverse()
      .map((name) => resolve(downloadsDir, name));
    candidates.push(...matched);
  }

  return candidates.find((p) => existsSync(p));
}

function resolveTnsAdmin() {
  if (!process.env.ORACLE_TNS_ADMIN) return undefined;
  return existsSync(process.env.ORACLE_TNS_ADMIN) ? process.env.ORACLE_TNS_ADMIN : undefined;
}

async function main() {
  const clientHome = resolveInstantClientHome();

  try {
    const tnsAdmin = resolveTnsAdmin();

    if (clientHome && tnsAdmin) {
      oracledb.initOracleClient({ libDir: clientHome, configDir: tnsAdmin });
    } else if (clientHome) {
      oracledb.initOracleClient({ libDir: clientHome });
    } else {
      oracledb.initOracleClient();
    }
  } catch (err) {
    console.error('Failed to initialize Oracle client:', err.message);
    console.error('Set ORACLE_CLIENT_HOME or install Oracle Instant Client');
    process.exit(1);
  }

  const tnsName = process.env.ORACLE_TNS_NAME || 'TESTING_AWS';
  const username = process.env.ORACLE_USER;
  const password = process.env.ORACLE_PASSWORD;

  if (!username || !password) {
    console.error('Missing required environment variables:');
    console.error('  ORACLE_USER, ORACLE_PASSWORD');
    process.exit(1);
  }

  let connection;
  try {
    connection = await oracledb.getConnection({
      user: username,
      password,
      connectionString: tnsName,
    });

    console.log(`Connected. Server version: ${connection.oracleServerVersionString}`);

    const result = await connection.execute('SELECT * FROM DBA_USERS', [], {
      outFormat: oracledb.OUT_FORMAT_OBJECT,
    });

    if (result.rows && result.rows.length > 0) {
      console.log(`USERNAME: ${result.rows[0].USERNAME}`);
    }
  } catch (err) {
    console.error('Connection failed:', err.message);
    process.exitCode = 1;
  } finally {
    if (connection) {
      try {
        await connection.close();
      } catch {
        // Ignore close errors on shutdown.
      }
    }
  }
}

main().catch((err) => {
  console.error('Unexpected error:', err);
  process.exit(1);
});
