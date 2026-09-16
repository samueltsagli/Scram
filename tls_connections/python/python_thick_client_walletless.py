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
    """Connect via the thick (Instant Client/OCI) driver, walletless.

    Resolves the connection from a TESTING_TLS alias, same descriptor as
    the canonical one in the Instant Client's own tnsnames.ora
    (<ORACLE_CLIENT_HOME>/network/admin/, alongside the wallet-based
    entries) - but reads it from tcps_client_config/ here instead, whose
    sqlnet.ora has no WALLET_LOCATION. The two can't be merged: the
    Instant Client's own sqlnet.ora sets WALLET_LOCATION, which is
    all-or-nothing for every entry that reads it, and that wallet is
    genuinely required for the old RDS-based entries (confirmed: removing
    it broke TESTING_AWS with ORA-29024). See tcps_client_config/sqlnet.ora
    for the full explanation.
    """

    load_dotenv()

    # Initialize Oracle client libs for thick mode. config_dir points at
    # tcps_client_config/ (wallet-free) rather than the Instant Client's
    # own network/admin (wallet-based) - see the docstring above.
    instant_client_home = resolve_instant_client_home()
    config_dir = str(Path(__file__).with_name("tcps_client_config"))
    try:
        if instant_client_home:
            oracledb.init_oracle_client(lib_dir=instant_client_home, config_dir=config_dir)
        else:
            oracledb.init_oracle_client(config_dir=config_dir)
    except Exception as e:
        print(f"Failed to initialize Oracle client: {e}")
        print("Set ORACLE_CLIENT_HOME or install Oracle Instant Client")
        return

    # Not read from ORACLE_TNS_NAME: that var is already used by
    # python_thick_client.py for its (wallet-based) TESTING_AWS alias in a
    # different tnsnames.ora, and reusing it here would collide.
    tns_name    = "TESTING_TLS"
    username    = os.environ["ORACLE_USER"]
    password    = os.environ["ORACLE_PASSWORD"]

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
