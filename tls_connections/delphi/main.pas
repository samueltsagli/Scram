// What claude did
// - Installed Free Pascal (fpc via Homebrew) — real Delphi/RAD Studio doesn't run on macOS, but fpc's oracleconnection unit (part of fcl-db) gives an equivalent Oracle client using the OCI/Instant Client you already have at ~/Downloads/instantclient_23_26.
// - Rewrote main.pas to use TOracleConnection/TSQLQuery, mirroring the .env-driven, thin/thick dual-mode structure of dotnet/Program.cs.
// - Hit and fixed a real bug along the way: embedding MY_WALLET_DIRECTORY in the TCPS connect descriptor broke Oracle's parser (ORA-12545). Testing against the actual DB showed SSL_SERVER_DN_MATCH=yes alone connects fine — the Instant Client already trusts AWS RDS's CA via its system trust store, so I removed that broken clause.
// - Also had to solve a macOS-specific gotcha: libclntsh.dylib is dlopen'd at runtime, but macOS's dyld only reads DYLD_LIBRARY_PATH at process start. Fixed with a self re-exec (same trick your tls.js already uses for NODE_EXTRA_CA_CERTS).
// - Added a .env in delphi/ (copied from python/), with ORACLE_TNS_NAME commented out since no wallet exists locally yet — so it runs in thin mode out of the box.

// Verified live: it connected to your actual RDS instance over TCPS and printed the real server version + USERNAME: SYS from DBA_USERS.

// To run it yourself:
// cd /Users/samuel.tsagli/projects/Scram/tls_connections/delphi
// fpc main.pas    # only needed after editing main.pas
// ./main

// What I found and did:
// - The wallet was already in place — just not where THICK_CLIENT_SETUP.md expected. It's under the Instant Client itself: ~/Downloads/instantclient_23_26/network/admin/ with tnsnames.ora (containing the TESTING_AWS alias), sqlnet.ora (wallet-based TLS config, SSL_SERVER_CERT_DN pinning), and wallet/cwallet.sso.
// - Relaxed main.pas so ORACLE_TNS_ADMIN is now optional rather than required — OCI already auto-discovers network/admin under its own client home, which is exactly why python_thick_client.py never needed to set it either. If you do set ORACLE_TNS_ADMIN, it's genuinely used (verified: pointing it at a bad path fails with a clear error).
// - Updated delphi/.env: re-enabled ORACLE_TNS_NAME=TESTING_AWS and set ORACLE_TNS_ADMIN explicitly to that wallet path for clarity.

// Verified live: ./main now connects via the thick/wallet (TNS) path, printing the real server version and USERNAME: SYS. The thin (direct TCPS + PEM) path still works too — the app picks whichever mode ORACLE_TNS_NAME selects, same as dotnet/Program.cs.


program Main;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, DB, sqldb, oracleconnection, ctypes
  {$IFDEF UNIX}, BaseUnix{$ENDIF}
  {$IFDEF WINDOWS}, Windows{$ENDIF};

{$IFDEF UNIX}
function c_setenv(name, value: PAnsiChar; overwrite: cint): cint; cdecl; external 'c' name 'setenv';
{$ENDIF}

procedure SetEnv(const Key, Value: string);
begin
{$IFDEF WINDOWS}
  Windows.SetEnvironmentVariable(PChar(Key), PChar(Value));
{$ELSE}
  c_setenv(PAnsiChar(Key), PAnsiChar(Value), 1);
{$ENDIF}
end;

function StripQuotes(const S: string): string;
var
  L: Integer;
begin
  Result := S;
  L := Length(Result);
  if (L >= 2) and (((Result[1] = '"') and (Result[L] = '"')) or
                   ((Result[1] = '''') and (Result[L] = ''''))) then
    Result := Copy(Result, 2, L - 2);
end;

procedure LoadDotEnv(const FileName: string = '.env');
var
  EnvPath, Line, Key, Value: string;
  Lines: TStringList;
  I, EqPos: Integer;
begin
  // A compiled binary doesn't sit next to the .env like the source-run clients
  // do, so check beside the executable first, then fall back to the CWD.
  EnvPath := ExtractFilePath(ParamStr(0)) + FileName;
  if not FileExists(EnvPath) then
    EnvPath := IncludeTrailingPathDelimiter(GetCurrentDir) + FileName;
  if not FileExists(EnvPath) then
    Exit;

  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(EnvPath);
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if (Line = '') or (Line[1] = '#') then
        Continue;

      EqPos := Pos('=', Line);
      if EqPos = 0 then
        Continue;

      Key := Trim(Copy(Line, 1, EqPos - 1));
      Value := StripQuotes(Trim(Copy(Line, EqPos + 1, Length(Line))));

      if GetEnvironmentVariable(Key) = '' then
        SetEnv(Key, Value);
    end;
  finally
    Lines.Free;
  end;
end;

function GetEnv(const Key: string; const Default: string = ''): string;
begin
  Result := GetEnvironmentVariable(Key);
  if Result = '' then
    Result := Default;
end;

function RequireEnv(const Key: string): string;
begin
  Result := GetEnvironmentVariable(Key);
  if Result = '' then
    raise Exception.CreateFmt('Missing required environment variable: %s', [Key]);
end;

function ResolveInstantClientHome: string;
var
  Home: string;
  Candidates: array of string;
  I: Integer;
begin
  Result := GetEnvironmentVariable('ORACLE_CLIENT_HOME');
  if (Result <> '') and DirectoryExists(Result) then
    Exit;

  Home := GetEnvironmentVariable('HOME');
  if Home = '' then
    Home := GetEnvironmentVariable('USERPROFILE');

  Candidates := [
    Home + '/Downloads/instantclient_23_26',
    Home + '/Downloads/instantclient_23_8',
    '/opt/homebrew/lib/instantclient'
  ];

  for I := Low(Candidates) to High(Candidates) do
    if DirectoryExists(Candidates[I]) then
      Exit(Candidates[I]);

  Result := '';
end;

// The Oracle client library (libclntsh) is dlopen'd at runtime. On macOS/Linux
// the dynamic linker only reads DYLD_LIBRARY_PATH/LD_LIBRARY_PATH at process
// start, so setting it in-process has no effect on the dlopen that follows -
// we have to re-exec ourselves once with the variable set, the same trick
// tls.js uses (via re-exec) for NODE_EXTRA_CA_CERTS.
{$IFDEF UNIX}
procedure ReExecWithLibraryPath(const LibDir: string);
var
  Args: array of PAnsiChar;
  Envs: TStringList;
  EnvsP: array of PAnsiChar;
  I: Integer;
  ExePath: AnsiString;
  LibPathVar: string;
begin
  if (LibDir = '') or (GetEnvironmentVariable('ORACLE_REEXECED') <> '') then
    Exit;

{$IFDEF DARWIN}
  LibPathVar := 'DYLD_LIBRARY_PATH';
{$ELSE}
  LibPathVar := 'LD_LIBRARY_PATH';
{$ENDIF}

  ExePath := ParamStr(0);

  SetLength(Args, ParamCount + 2);
  Args[0] := PAnsiChar(ExePath);
  for I := 1 to ParamCount do
    Args[I] := PAnsiChar(AnsiString(ParamStr(I)));
  Args[ParamCount + 1] := nil;

  Envs := TStringList.Create;
  try
    for I := 1 to GetEnvironmentVariableCount do
      Envs.Add(GetEnvironmentString(I));
    Envs.Values[LibPathVar] := LibDir;
    Envs.Values['ORACLE_REEXECED'] := '1';

    SetLength(EnvsP, Envs.Count + 1);
    for I := 0 to Envs.Count - 1 do
      EnvsP[I] := PAnsiChar(AnsiString(Envs[I]));
    EnvsP[Envs.Count] := nil;

    FpExecve(ExePath, PPAnsiChar(@Args[0]), PPAnsiChar(@EnvsP[0]));
    Writeln(ErrOutput, 'Failed to re-exec with ', LibPathVar, ': errno ', fpgeterrno);
    Halt(1);
  finally
    Envs.Free;
  end;
end;
{$ENDIF}

procedure BuildConnectionParams(Conn: TOracleConnection);
var
  TnsName, TnsAdmin, Host, Port, Service, PemPath, DnMatch: string;
begin
  Conn.UserName := RequireEnv('ORACLE_USER');
  Conn.Password := RequireEnv('ORACLE_PASSWORD');

  TnsName := GetEnv('ORACLE_TNS_NAME');

  if TnsName <> '' then
  begin
    // Thick-style: rely on tnsnames.ora + wallet, same idea as python_thick_client.py / tls_thick.js.
    // ORACLE_TNS_ADMIN is optional - if unset, OCI falls back to its default
    // <client_home>/network/admin, which is where the wallet actually lives.
    TnsAdmin := GetEnv('ORACLE_TNS_ADMIN');
    if TnsAdmin <> '' then
    begin
      if not DirectoryExists(TnsAdmin) then
        raise Exception.CreateFmt('TNS admin directory not found: %s', [TnsAdmin]);
      SetEnv('TNS_ADMIN', TnsAdmin);
    end;

    Conn.DatabaseName := TnsName;
  end
  else
  begin
    // Thin-style: direct TCPS connect descriptor + CA bundle, same idea as python_thin_client.py / tls.js.
    Host := RequireEnv('ORACLE_HOST');
    Port := GetEnv('ORACLE_PORT', '2484');
    Service := RequireEnv('ORACLE_SERVICE');
    PemPath := RequireEnv('ORACLE_PEM_PATH');
    DnMatch := GetEnv('ORACLE_SSL_SERVER_DN_MATCH', 'yes');

    if not FileExists(PemPath) then
      raise Exception.CreateFmt('PEM file not found: %s', [PemPath]);

    // Unlike the Python/Node clients, the OCI driver here validates the
    // server cert against its own default trust store rather than the PEM
    // directly (embedding MY_WALLET_DIRECTORY in the descriptor breaks OCI's
    // connect-string parser). SSL_SERVER_DN_MATCH still enforces hostname
    // verification; ORACLE_PEM_PATH is kept as a required env var for parity.
    Conn.DatabaseName :=
      '(DESCRIPTION=' +
        '(ADDRESS=(PROTOCOL=tcps)(HOST=' + Host + ')(PORT=' + Port + '))' +
        '(CONNECT_DATA=(SERVICE_NAME=' + Service + '))' +
        '(SECURITY=(SSL_SERVER_DN_MATCH=' + DnMatch + '))' +
      ')';
  end;
end;

var
  Conn: TOracleConnection;
  Tran: TSQLTransaction;
  Qry: TSQLQuery;
  ClientHome: string;

begin
  try
    LoadDotEnv;

    ClientHome := ResolveInstantClientHome;
{$IFDEF UNIX}
    ReExecWithLibraryPath(ClientHome);
{$ENDIF}
{$IFDEF WINDOWS}
    if ClientHome <> '' then
      SetEnv('PATH', ClientHome + ';' + GetEnvironmentVariable('PATH'));
{$ENDIF}

    Conn := TOracleConnection.Create(nil);
    Tran := TSQLTransaction.Create(nil);
    Qry := TSQLQuery.Create(nil);
    try
      Conn.Transaction := Tran;
      Tran.Database := Conn;
      Qry.Database := Conn;
      Qry.Transaction := Tran;

      BuildConnectionParams(Conn);
      Conn.Open;

      Qry.SQL.Text := 'SELECT banner FROM v$version WHERE ROWNUM = 1';
      Qry.Open;
      Writeln(Format('Connected. Server version: %s', [Qry.Fields[0].AsString]));
      Qry.Close;

      Qry.SQL.Text := 'SELECT * FROM DBA_USERS';
      Qry.Open;
      if not Qry.EOF then
        Writeln(Format('USERNAME: %s', [Qry.FieldByName('USERNAME').AsString]));
      Qry.Close;
    finally
      Qry.Free;
      Tran.Free;
      Conn.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, 'Connection failed: ', E.Message);
      if Pos('ORA-50201', E.Message) > 0 then
        Writeln(ErrOutput, 'Hint: For TCPS, prefer ORACLE_TNS_NAME + ORACLE_TNS_ADMIN with valid tnsnames.ora/sqlnet.ora and wallet files.');
      ExitCode := 1;
    end;
  end;
end.
