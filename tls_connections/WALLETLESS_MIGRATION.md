# Wallet → Walletless Migration (Thin Clients)

What changed in each thin-client application when its Oracle TCPS connection stopped
depending on a wallet (or PEM CA bundle) and started trusting the server's cert straight
out of the OS/runtime's default trust store.

**Scope:** thin-client variants only. Thick/TNS+wallet variants
(`python_thick_client*.py`, `tls_thick*.js`, `dotnet_thick_walletless`, the
`ORACLE_TNS_NAME` branch of `main.pas`, `main_thick_walletless.pas`) are **not** covered
here — see [`THICK_CLIENT_SETUP.md`](./THICK_CLIENT_SETUP.md) for those. `ec2/` and
`lambda/` contain no application code yet.

## How the trust model changes

Every app here talks TCPS (TLS-wrapped Oracle Net) directly to `host:port/service` — no
listener-side change, only how the *client* decides to trust the server's certificate.

**Before — wallet**
1. Server presents a cert signed by a private/internal CA.
2. Client loads that CA explicitly — PEM file, wallet, or `sqlnet.ora`.
3. Client verifies the hostname against the cert's CN.

**After — walletless**
1. Server presents a cert signed by a publicly-trusted CA.
2. Client uses its default trust store — nothing to load.
3. Client pins the expected DN (`ORACLE_SSL_SERVER_CERT_DN`) if the connect host ≠ cert CN.

The one wrinkle every walletless variant shares: the server cert's CN is often a friendly
alias rather than the literal `ORACLE_HOST` used to connect, so hostname verification would
fail even though the cert is legitimately trusted. Each client below pins the expected
Distinguished Name (`ORACLE_SSL_SERVER_CERT_DN`) instead of relying on hostname comparison.

## Quick reference

| Application | Wallet-only env var | Added for walletless | Renamed | Notes |
|---|---|---|---|---|
| Python (`python-oracledb`, thin) | `ORACLE_PEM_PATH` | `ORACLE_SSL_SERVER_CERT_DN` (optional) | `ORACLE_SERVICE` → `SERVICE_NAME` | Custom `ssl.SSLContext` dropped entirely |
| Node.js (`node-oracledb`, thin) | `ORACLE_PEM_PATH` | `ORACLE_SSL_SERVER_CERT_DN` (optional) | `ORACLE_SERVICE` → `SERVICE_NAME` | Drops the `NODE_EXTRA_CA_CERTS` re-exec bootstrap |
| .NET (ODP.NET managed, direct TCPS) | `ORACLE_PEM_PATH` → `SSL_CERT_FILE` | `ORACLE_SSL_SERVER_CERT_DN` (optional) | — kept `ORACLE_SERVICE` | Separate project (`dotnet_direct_tls`), not a branch |
| Delphi (Free Pascal + OCI, direct TCPS) | `ORACLE_PEM_PATH` | `ORACLE_SSL_SERVER_CERT_DN` (optional) | — kept `ORACLE_SERVICE` | PEM was already vestigial — see note below |

## Python

`python_thin_client.py` → `python_thin_client_walletless.py`

python-oracledb's thin mode talks TCPS itself, so trust is just an `ssl.SSLContext` the
driver is handed.

**Wallet**
- Builds a custom `SSLContext`, loads the CA via `ctx.load_verify_locations(cafile=ORACLE_PEM_PATH)`, hostname checking on.
- Passes it in as `ConnectParams(ssl_context=ctx)`.
- Requires: `ORACLE_HOST`, `ORACLE_PORT`, `ORACLE_SERVICE`, `ORACLE_USER`, `ORACLE_PASSWORD`, `ORACLE_PEM_PATH`.

```python
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.load_verify_locations(cafile=pem_path)
params = oracledb.ConnectParams(..., ssl_context=ctx)
```

**Walletless**
- No `ssl` import at all — driver's default context (system trust store) is used as-is.
- Optional `ssl_server_cert_dn` pins the expected DN.
- Requires: `ORACLE_HOST`, `ORACLE_PORT`, `SERVICE_NAME`, `ORACLE_USER`, `ORACLE_PASSWORD`; optional `ORACLE_SSL_SERVER_CERT_DN`.

```python
params = oracledb.ConnectParams(
    ..., ssl_server_cert_dn=server_dn
)
```

> **Watch for:** the service-name env var is renamed `ORACLE_SERVICE` → `SERVICE_NAME` in
> the walletless script — copying the old `.env` as-is will fail with a `KeyError`, not a
> TLS error.

## Node.js

`tls.js` → `tls_walletless.js`

node-oracledb's default (thin) mode has the same TCPS-in-driver shape as Python, but
Node's CA trust is process-wide, not per-connection.

**Wallet**
- Reads `ORACLE_PEM_PATH`, then re-execs itself with `NODE_EXTRA_CA_CERTS` set — Node only reads that variable at process start, so it can't be set mid-run.
- Requires: `ORACLE_HOST`, `ORACLE_SERVICE`, `ORACLE_USER`, `ORACLE_PASSWORD`, `ORACLE_PEM_PATH`.

```js
spawnSync(process.execPath, argv, { env: {
  ...env, NODE_EXTRA_CA_CERTS: resolvedPem,
}})
```

**Walletless**
- The whole re-exec/bootstrap function is gone — nothing to set before the process starts.
- Optional `sslServerCertDN` spread into `getConnection()` when set.
- Requires: `ORACLE_HOST`, `SERVICE_NAME`, `ORACLE_USER`, `ORACLE_PASSWORD`; optional `ORACLE_SSL_SERVER_CERT_DN`.

```js
oracledb.getConnection({
  ..., ...(sslServerCertDN ? { sslServerCertDN } : {}),
})
```

> **Watch for:** same rename as Python — `ORACLE_SERVICE` becomes `SERVICE_NAME`. Also,
> since the re-exec is gone, walletless starts noticeably faster (one process instead of two).

## .NET

`dotnet/Program.cs` → `dotnet_direct_tls/Program.cs`

ODP.NET managed builds a raw Oracle Net connect descriptor either way. Unlike the other
three apps, the walletless version lives in its **own project** (`dotnet_direct_tls`),
not a branch of the original — the original `dotnet` app still supports a separate
thick/TNS+wallet path alongside its thin path.

**Wallet (thin branch)**
- Requires `ORACLE_PEM_PATH` to exist, then sets `SSL_CERT_FILE` to it so ODP.NET's TLS stack trusts that CA.
- Requires: `ORACLE_HOST`, `ORACLE_SERVICE`, `ORACLE_USER`, `ORACLE_PASSWORD`, `ORACLE_PEM_PATH`.

```csharp
Environment.SetEnvironmentVariable("SSL_CERT_FILE", pemPath);
```

**Walletless**
- No `SSL_CERT_FILE` / `ORACLE_PEM_PATH` — relies on the OS certificate store.
- Adds a `NormalizeYesNo` helper so `SSL_SERVER_DN_MATCH` tolerates `true`/`on`/`1` instead of only Oracle's literal `yes`/`no`.
- Appends `SSL_SERVER_CERT_DN="..."` to the descriptor's `SECURITY` clause when set.
- Requires: `ORACLE_HOST`, `ORACLE_SERVICE`, `ORACLE_USER`, `ORACLE_PASSWORD`; optional `ORACLE_PORT`, `ORACLE_SSL_SERVER_DN_MATCH`, `ORACLE_SSL_SERVER_CERT_DN`.

```
(SECURITY=(SSL_SERVER_DN_MATCH=yes)(SSL_SERVER_CERT_DN="..."))
```

> **Watch for:** this app kept `ORACLE_SERVICE` (it did *not* rename to `SERVICE_NAME` like
> Python/Node) — the env var naming isn't consistent across languages, so don't copy one
> app's `.env` onto another without checking.

## Delphi

`main.pas` (thin branch) → `main_walletless.pas`

Same direct-descriptor shape as .NET, via Free Pascal's OCI-backed `oracleconnection`
unit. `main.pas` also supports a thick/TNS branch (selected by setting `ORACLE_TNS_NAME`)
— out of scope here.

**Wallet (thin branch)**
- Checks that `ORACLE_PEM_PATH` exists on disk and requires it — but the OCI driver actually validates against its *own* default trust store, not the PEM directly (embedding the wallet dir into the descriptor broke OCI's parser).
- Requires: `ORACLE_HOST`, `ORACLE_SERVICE`, `ORACLE_USER`, `ORACLE_PASSWORD`, `ORACLE_PEM_PATH` (existence only).

```pascal
if not FileExists(PemPath) then
  raise Exception.CreateFmt('PEM file not found...');
// PemPath itself is never loaded into the driver
```

**Walletless**
- `ORACLE_PEM_PATH` dropped completely — no file check, no env var.
- Adds optional `ORACLE_SSL_SERVER_CERT_DN`, appended into the `SECURITY` clause.
- Requires: `ORACLE_HOST`, `ORACLE_SERVICE`, `ORACLE_USER`, `ORACLE_PASSWORD`; optional `ORACLE_PORT`, `ORACLE_SSL_SERVER_DN_MATCH`, `ORACLE_SSL_SERVER_CERT_DN`.

```pascal
if ServerCertDn = '' then
  Security := '(SECURITY=(SSL_SERVER_DN_MATCH=' + DnMatch + '))'
else
  Security := '...(SSL_SERVER_CERT_DN="' + ServerCertDn + '"))';
```

> **Watch for:** the wallet variant's `ORACLE_PEM_PATH` requirement was already dead weight
> before this migration — it gated startup but was never handed to the TLS layer.
> Functionally, the wallet and walletless thin builds trusted the server cert identically;
> walletless just removes the unused file dependency. Both still need the Instant Client's
> OCI libraries on the library path (unrelated to wallet vs walletless).

<!-- shoutout to claude -->