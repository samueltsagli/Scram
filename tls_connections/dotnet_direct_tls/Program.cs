using Oracle.ManagedDataAccess.Client;

static void LoadDotEnv(string path)
{
	if (!File.Exists(path)) return;
	foreach (var line in File.ReadLines(path).Select(x => x.Trim()))
	{
		if (line.Length == 0 || line.StartsWith("#")) continue;
		var parts = line.Split('=', 2);
		if (parts.Length != 2 || !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(parts[0]))) continue;
		Environment.SetEnvironmentVariable(parts[0].Trim(), parts[1].Trim().Trim('"', '\''));
	}
}

static string Required(string key) =>
	Environment.GetEnvironmentVariable(key) is { Length: > 0 } v ? v : throw new InvalidOperationException($"Missing required environment variable: {key}");

// Oracle's connect descriptor only accepts yes/no for SSL_SERVER_DN_MATCH;
// an invalid value like "true" makes ODP.NET fail with a generic
// ORA-50201 "failed to parse connect string" rather than a clear error,
// so normalize common boolean spellings instead of passing the raw value through.
static string NormalizeYesNo(string? value, string defaultValue)
{
	if (string.IsNullOrWhiteSpace(value)) return defaultValue;
	return value.Trim().ToLowerInvariant() switch
	{
		"true" or "yes" or "on" or "1" => "yes",
		"false" or "no" or "off" or "0" => "no",
		_ => value
	};
}

// Walletless: no ORACLE_PEM_PATH / SSL_CERT_FILE. A walletless endpoint
// presents a publicly-trusted cert, so ODP.NET's default TLS trust (the
// OS certificate store) is enough. If the cert's CN doesn't match
// ORACLE_HOST, set ORACLE_SSL_SERVER_CERT_DN to pin the expected DN
// instead of relying on hostname comparison.
try
{
	OracleConfiguration.TraceFileLocation = "/tmp/odpnet_trace";
	OracleConfiguration.TraceLevel = 7;
	LoadDotEnv(".env");

	var host = Required("ORACLE_HOST");
	var port = Environment.GetEnvironmentVariable("ORACLE_PORT") ?? "2484";
	var service = Required("ORACLE_SERVICE");
	var user = Required("ORACLE_USER");
	var password = Required("ORACLE_PASSWORD");
	var sslServerDnMatch = NormalizeYesNo(Environment.GetEnvironmentVariable("ORACLE_SSL_SERVER_DN_MATCH"), "yes");
	var sslServerCertDn = Environment.GetEnvironmentVariable("ORACLE_SSL_SERVER_CERT_DN");

	var security = string.IsNullOrWhiteSpace(sslServerCertDn)
		? $"(SECURITY=(SSL_SERVER_DN_MATCH={sslServerDnMatch}))"
		: $"(SECURITY=(SSL_SERVER_DN_MATCH={sslServerDnMatch})(SSL_SERVER_CERT_DN=\"{sslServerCertDn}\"))";

	var dataSource = $"(DESCRIPTION=(ADDRESS=(PROTOCOL=tcps)(HOST={host})(PORT={port}))(CONNECT_DATA=(SERVICE_NAME={service})){security})";

	var csb = new OracleConnectionStringBuilder
	{
		UserID = user,
		Password = password,
		DataSource = dataSource
	};

	using var connection = new OracleConnection(csb.ConnectionString);
	connection.Open();
	Console.WriteLine($"Connected. Server version: {connection.ServerVersion}");

	using var command = connection.CreateCommand();
	command.CommandText = "SELECT * FROM DBA_USERS";
	var username = command.ExecuteScalar();
	Console.WriteLine($"USERNAME: {username}");
}
catch (Exception ex)
{
	Console.Error.WriteLine($"Connection failed: {ex.Message}");
	if (ex.InnerException is not null) Console.Error.WriteLine($"Inner error: {ex.InnerException.Message}");
	Environment.Exit(1);
}
