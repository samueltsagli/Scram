// Walletless variant of main.pas: connects over TCPS without a wallet or
// ORACLE_PEM_PATH. A walletless endpoint presents a publicly-trusted cert,
// so the Instant Client's default OS trust store is enough. If the cert's
// CN doesn't match ORACLE_HOST, set ORACLE_SSL_SERVER_CERT_DN to pin the
// expected DN instead of relying on hostname comparison.

program MainWalletless;

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
// main.pas and tls.js use.
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
  Host, Port, Service, DnMatch, ServerCertDn, Security: string;
begin
  Conn.UserName := RequireEnv('ORACLE_USER');
  Conn.Password := RequireEnv('ORACLE_PASSWORD');

  // Thin-style only: direct TCPS connect descriptor, no wallet/PEM.
  Host := RequireEnv('ORACLE_HOST');
  Port := GetEnv('ORACLE_PORT', '2484');
  Service := RequireEnv('ORACLE_SERVICE');
  DnMatch := GetEnv('ORACLE_SSL_SERVER_DN_MATCH', 'yes');
  ServerCertDn := GetEnv('ORACLE_SSL_SERVER_CERT_DN');

  if ServerCertDn = '' then
    Security := '(SECURITY=(SSL_SERVER_DN_MATCH=' + DnMatch + '))'
  else
    Security := '(SECURITY=(SSL_SERVER_DN_MATCH=' + DnMatch + ')(SSL_SERVER_CERT_DN="' + ServerCertDn + '"))';

  Conn.DatabaseName :=
    '(DESCRIPTION=' +
      '(ADDRESS=(PROTOCOL=tcps)(HOST=' + Host + ')(PORT=' + Port + '))' +
      '(CONNECT_DATA=(SERVICE_NAME=' + Service + '))' +
      Security +
    ')';
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
      ExitCode := 1;
    end;
  end;
end.
