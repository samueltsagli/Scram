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

try
{
	OracleConfiguration.TraceFileLocation = "/tmp/odpnet_trace";
	OracleConfiguration.TraceLevel = 7;
	LoadDotEnv(".env");
	var service = Required("ORACLE_SERVICE");
	var user = Required("ORACLE_USER");
	var password = Required("ORACLE_PASSWORD");
	var pemPath = Required("ORACLE_PEM_PATH");
	if (!File.Exists(pemPath)) throw new FileNotFoundException($"PEM file not found: {pemPath}");
	Environment.SetEnvironmentVariable("SSL_CERT_FILE", pemPath);

	var tnsName = Environment.GetEnvironmentVariable("ORACLE_TNS_NAME");
	var tnsAdmin = Environment.GetEnvironmentVariable("ORACLE_TNS_ADMIN");
	var dataSource = string.Empty;

	if (!string.IsNullOrWhiteSpace(tnsName))
	{
		if (string.IsNullOrWhiteSpace(tnsAdmin))
			throw new InvalidOperationException("ORACLE_TNS_ADMIN is required when ORACLE_TNS_NAME is set.");
		if (!Directory.Exists(tnsAdmin))
			throw new DirectoryNotFoundException($"TNS admin directory not found: {tnsAdmin}");

		OracleConfiguration.TnsAdmin = tnsAdmin;
		dataSource = tnsName;
	}
	else
	{
		var host = Required("ORACLE_HOST");
		var port = Environment.GetEnvironmentVariable("ORACLE_PORT") ?? "2484";
		var sslServerDnMatch = Environment.GetEnvironmentVariable("ORACLE_SSL_SERVER_DN_MATCH") ?? "yes";
		dataSource = $"(DESCRIPTION=(ADDRESS=(PROTOCOL=tcps)(HOST={host})(PORT={port}))(CONNECT_DATA=(SERVICE_NAME={service}))(SECURITY=(SSL_SERVER_DN_MATCH={sslServerDnMatch})))";
	}

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
	if (ex.Message.Contains("ORA-50201", StringComparison.OrdinalIgnoreCase))
	{
		Console.Error.WriteLine("Hint: For .NET TCPS, prefer ORACLE_TNS_NAME + ORACLE_TNS_ADMIN with valid tnsnames.ora/sqlnet.ora and wallet files.");
	}
	Environment.Exit(1);
}
