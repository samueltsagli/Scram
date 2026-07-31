# Oracle Thick Client Setup with Wallet

## What You Need

- [x] `cwallet.sso` (encrypted wallet file) — you have this
- [ ] `ewallet.p12` or `ewallet.pem` (optional, but recommended for backup)
- [ ] Oracle Instant Client (basic + sqlplus packages)
- [ ] `tnsnames.ora` (TNS name mappings)
- [ ] `sqlnet.ora` (SQL*Net configuration)

## Installation Steps

### 1. Install Oracle Instant Client

**macOS** (via Homebrew):
```bash
brew tap oracle/tap
brew install oracle-instantclient
```

**Linux** (Ubuntu/Debian):
```bash
sudo apt-get install oracle-instantclient-basic oracle-instantclient-sqlplus
```

**Other OS**: Download from [Oracle's website](https://www.oracle.com/database/technologies/instant-client/downloads.html)

### 2. Set Environment Variables

```bash
export ORACLE_CLIENT_HOME="/usr/local/lib/oracle/instantclient_23_15"  # adjust version
export TNS_ADMIN="/Users/samuel.tsagli/projects/Scram/tls_connections/wallet"
export ORACLE_TNS_NAME="TESTING_AWS"
```

Or add to `~/.zshrc` for persistence.

### 3. Place Your Wallet Files

Copy your wallet files to the `wallet/` directory:
```bash
cp /path/to/cwallet.sso wallet/
cp /path/to/ewallet.p12 wallet/  # optional
```

### 4. Edit `tnsnames.ora`

Replace the hostname and other details with your actual RDS instance:
- **HOST**: your RDS endpoint
- **PORT**: 2484 (TLS port)
- **SERVICE_NAME**: your Oracle service name
- **SSL_SERVER_DN_MATCH**: set to yes for certificate verification

### 5. Run the Script

```bash
source .venv/bin/activate
python3 python_thick_client.py
```

## What Happens with the Wallet

- The wallet stores encrypted credentials (username/password)
- `sqlnet.ora` tells Oracle where to find it (`WALLET_LOCATION`)
- On connect, Oracle decrypts and auto-authenticates using wallet creds
- You **don't pass credentials** in the Python code — they come from the wallet

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `ORA-12514` | TNS name not found | Verify `TNS_ADMIN` points to correct directory |
| `ORA-12152` | Wallet not found | Check `WALLET_LOCATION` path in `sqlnet.ora` |
| `ORA-01031` | Bad wallet credentials | Verify wallet was created with correct user/pass |
| `SSL/TLS` errors | Certificate mismatch | Set `SSL_SERVER_DN_MATCH` and verify cert DN |

## Thin vs. Thick Client

| Aspect | Thin | Thick |
|---|---|---|
| **Requires** | Just `oracledb` package | Oracle Instant Client + client libs |
| **TLS** | Direct SSL context (PEM file) | Via wallet + `sqlnet.ora` |
| **Speed** | Slightly faster startup | Slower (loads native libs) |
| **Features** | Basic | Full SQL*Plus, advanced features |
| **Use case** | Cloud/containerized | Enterprise/legacy systems |
