import os
from pathlib import Path
import oracledb


def load_dotenv(file_name: str = ".env") -> None:
    env_path = Path(__file__).with_name(file_name)
    if not env_path.exists():
        return

    for raw_line in env_path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if not os.environ.get(key):
            os.environ[key] = value


def main():
    """Connect over TCPS without a wallet/custom CA bundle.

    Walletless Oracle TLS endpoints present a publicly-trusted CA cert, so
    python-oracledb's default SSL context (system trust store) is enough —
    no ORACLE_PEM_PATH / custom SSLContext required.
    """
    load_dotenv()

    host        = os.environ["ORACLE_HOST"]
    port        = int(os.environ.get("ORACLE_PORT", "2484"))
    service     = os.environ["SERVICE_NAME"]
    username    = os.environ["ORACLE_USER"]
    password    = os.environ["ORACLE_PASSWORD"]
    server_dn   = os.environ.get("ORACLE_SSL_SERVER_CERT_DN")

    # The server cert's CN doesn't match ORACLE_HOST (it's a friendly alias,
    # not the connect hostname), so pin the expected DN instead of relying
    # on hostname comparison.
    params = oracledb.ConnectParams(
        host=host,
        port=port,
        service_name=service,
        protocol="tcps",
        ssl_server_cert_dn=server_dn,
    )

    with oracledb.connect(
        user=username,
        password=password,
        params=params,
    ) as conn:
        print(f"Connected. Server version: {conn.version}")

        with conn.cursor() as cursor:
            cursor.execute("SELECT * FROM DBA_USERS")
            row = cursor.fetchone()
            print(f"USERNAME: {row[0]}")


if __name__ == "__main__":
    main()
