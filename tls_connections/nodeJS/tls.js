import 'dotenv/config';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

function bootstrapCaTrust() {
  const pemPath = process.env.ORACLE_PEM_PATH;
  if (!pemPath) return;

  const resolvedPem = resolve(pemPath);
  if (!existsSync(resolvedPem)) {
    console.error(`ORACLE_PEM_PATH file not found: ${resolvedPem}`);
    process.exit(1);
  }

  // NODE_EXTRA_CA_CERTS is read when Node starts, so set it via one-time re-exec.
  if (!process.env.NODE_EXTRA_CA_CERTS && !process.env.ORACLE_REEXECED) {
    const child = spawnSync(process.execPath, process.argv.slice(1), {
      stdio: 'inherit',
      env: {
        ...process.env,
        NODE_EXTRA_CA_CERTS: resolvedPem,
        ORACLE_REEXECED: '1',
      },
    });
    process.exit(child.status ?? 1);
  }
}

async function main() {
  bootstrapCaTrust();
  const oracledb = (await import('oracledb')).default;

  const host = process.env.ORACLE_HOST;
  const port = parseInt(process.env.ORACLE_PORT || '2484', 10);
  const service = process.env.ORACLE_SERVICE;
  const username = process.env.ORACLE_USER;
  const password = process.env.ORACLE_PASSWORD;
  const pemPath = process.env.ORACLE_PEM_PATH;

  // Validate environment variables
  if (!host || !service || !username || !password || !pemPath) {
    console.error('Missing required environment variables:');
    console.error('  ORACLE_HOST, ORACLE_SERVICE, ORACLE_USER, ORACLE_PASSWORD, ORACLE_PEM_PATH');
    process.exit(1);
  }

  try {
    // Configure thin client mode (default in Node.js oracledb)
    const connection = await oracledb.getConnection({
      user: username,
      password: password,
      connectionString: `tcps://${host}:${port}/${service}`,
    });


    const result = await connection.execute(
      `SELECT * FROM DBA_USERS`,
      [],
      { outFormat: oracledb.OUT_FORMAT_OBJECT }
    );

    if (result.rows.length > 0) {
      console.log(`USERNAME: ${result.rows[0].USERNAME}`);
    }

    await connection.close();
  } catch (err) {
    console.error('Connection failed:', err.message);
    process.exit(1);
  }
}

main().catch(err => {
  console.error('Unexpected error:', err);
  process.exit(1);
});
