import 'dotenv/config';

async function main() {
  const oracledb = (await import('oracledb')).default;

  const host = process.env.ORACLE_HOST;
  const port = parseInt(process.env.ORACLE_PORT || '2484', 10);
  const service = process.env.SERVICE_NAME;
  const username = process.env.ORACLE_USER;
  const password = process.env.ORACLE_PASSWORD;
  const sslServerCertDN = process.env.ORACLE_SSL_SERVER_CERT_DN;

  // Validate environment variables
  if (!host || !service || !username || !password) {
    console.error('Missing required environment variables:');
    console.error('  ORACLE_HOST, SERVICE_NAME, ORACLE_USER, ORACLE_PASSWORD');
    process.exit(1);
  }

  try {
    // Walletless: no ORACLE_PEM_PATH / NODE_EXTRA_CA_CERTS bootstrap. A
    // walletless endpoint presents a publicly-trusted cert, so Node's
    // default TLS trust store is enough. If the cert's CN doesn't match
    // ORACLE_HOST (e.g. it's a friendly alias rather than the connect
    // hostname), set ORACLE_SSL_SERVER_CERT_DN to pin the expected DN
    // instead of relying on hostname comparison.
    const connection = await oracledb.getConnection({
      user: username,
      password: password,
      connectionString: `tcps://${host}:${port}/${service}`,
      ...(sslServerCertDN ? { sslServerCertDN } : {}),
    });

    console.log(`Connected. Server version: ${connection.oracleServerVersionString}`);

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
