import os
import ssl
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


def get_ssl_context(pem_path: str) -> ssl.SSLContext:
    """Build an SSLContext that trusts only the CA cert(s) in the given PEM file."""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.check_hostname = True
    ctx.load_verify_locations(cafile=pem_path)
    return ctx


def main():
    load_dotenv()

    host        = os.environ["ORACLE_HOST"]
    port        = int(os.environ.get("ORACLE_PORT", "2484"))
    service     = os.environ["ORACLE_SERVICE"]
    username    = os.environ["ORACLE_USER"]
    password    = os.environ["ORACLE_PASSWORD"]
    pem_path    = os.environ["ORACLE_PEM_PATH"] 

    ssl_ctx = get_ssl_context(pem_path)

    params = oracledb.ConnectParams(
        host=host,
        port=port,
        service_name=service,
        protocol="tcps",
        ssl_context=ssl_ctx,
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
