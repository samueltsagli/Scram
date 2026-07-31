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


def resolve_instant_client_home() -> str | None:
    """Find Instant Client lib directory from env or common local install paths."""
    env_home = os.environ.get("ORACLE_CLIENT_HOME")
    if env_home and Path(env_home).exists():
        return env_home

    home = Path.home()
    candidates = [
        home / "Downloads" / "instantclient_23_26",
        home / "Downloads" / "instantclient_23_8",
        Path("/opt/homebrew/lib/instantclient"),
    ]

    # Also support any instantclient_* folder under Downloads.
    candidates.extend(sorted((home / "Downloads").glob("instantclient_*"), reverse=True))

    for path in candidates:
        if path.exists():
            return str(path)

    return None


def main():
    """Connect to Oracle using thick client with wallet-based TLS authentication."""

    load_dotenv()

    # Initialize Oracle client libs for thick mode.
    instant_client_home = resolve_instant_client_home()
    try:
        if instant_client_home:
            oracledb.init_oracle_client(lib_dir=instant_client_home)
        else:
            oracledb.init_oracle_client()
    except Exception as e:
        print(f"Failed to initialize Oracle client: {e}")
        print("Set ORACLE_CLIENT_HOME or install Oracle Instant Client")
        return

    # TNS name from environment or tnsnames.ora
    tns_name = os.environ.get("ORACLE_TNS_NAME", "TESTING_AWS")
    username = os.environ["ORACLE_USER"]
    password = os.environ["ORACLE_PASSWORD"]
    
    try:
        with oracledb.connect(
            dsn=tns_name,
            user=username,
            password=password,
        ) as conn:
            print(f"Connected. Server version: {conn.version}")
            
            with conn.cursor() as cursor:
                cursor.execute("SELECT * FROM DBA_USERS")
                row = cursor.fetchone()
                print(f"USERNAME: {row[0]}")
    except Exception as e:
        print(f"Connection failed: {e}")


if __name__ == "__main__":
    main()
