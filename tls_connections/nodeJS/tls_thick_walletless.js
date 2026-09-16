import 'dotenv/config';
import { existsSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';
import oracledb from 'oracledb';

// Walletless thick client: resolves the connection from the TESTING_TLS
// alias in ./tcps_client_config/tnsnames.ora instead of a wallet. That
// alias's SECURITY clause pins SSL_SERVER_CERT_DN, and
// tcps_client_config/sqlnet.ora has no WALLET_LOCATION/cipher restriction
// (initOracleClient() switches this process to the same native OCI stack
// as the Python/Delphi thick clients, which does NOT trust Amazon RDS's
// CA via the OS store by default - confirmed earlier - so it can't share
// the Instant Client's own wallet-based network/admin/sqlnet.ora).

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

async function main() {
  const clientHome = resolveInstantClientHome();
  const configDir = resolve(import.meta.dirname, 'tcps_client_config');

  try {
    if (clientHome) {
      oracledb.initOracleClient({ libDir: clientHome, configDir });
    } else {
      oracledb.initOracleClient({ configDir });
    }
  } catch (err) {
    console.error('Failed to initialize Oracle client:', err.message);
    console.error('Set ORACLE_CLIENT_HOME or install Oracle Instant Client');
    process.exit(1);
  }

  const tnsName = 'TESTING_TLS';
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
