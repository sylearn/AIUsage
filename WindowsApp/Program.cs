using System.Text.Json;

var command = args.FirstOrDefault()?.ToLowerInvariant() ?? "status";
var summary = new
{
    appName = "AIUsage Windows",
    version = "0.1.0",
    operatingSystem = Environment.OSVersion.VersionString,
    currentDirectory = Environment.CurrentDirectory,
    homeDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
};

switch (command)
{
    case "status":
        Console.WriteLine("AIUsage Windows build: ready");
        Console.WriteLine($"Operating system: {summary.operatingSystem}");
        Console.WriteLine($"Home directory: {summary.homeDirectory}");
        break;
    case "version":
        Console.WriteLine(summary.version);
        break;
    case "json":
        Console.WriteLine(JsonSerializer.Serialize(summary, new JsonSerializerOptions { WriteIndented = true }));
        break;
    case "help":
    case "-h":
    case "--help":
        Console.WriteLine("AIUsage.exe [status|version|json|help]");
        break;
    default:
        Console.Error.WriteLine($"Unknown command: {command}");
        Environment.ExitCode = 2;
        break;
}