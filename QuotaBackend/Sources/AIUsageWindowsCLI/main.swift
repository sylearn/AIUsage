import Foundation

let appName = "AIUsage Windows CLI"
let version = "0.1.0"

struct RuntimeSummary: Codable {
    let appName: String
    let version: String
    let operatingSystem: String
    let currentDirectory: String
    let homeDirectory: String
}

/// Prints the app name, version, usage, and command descriptions to standard output.
func printHelp() {
    print("""
\(appName) v\(version)

Usage:
  AIUsageWindowsCLI [command]

Commands:
  status      Show a minimal health check for the Windows build.
  version     Print the app version.
  help        Show this help text.
  env         Print environment variables relevant to a Windows build.
  json        Emit a JSON summary for tooling and packaging automation.
""")
}

/// Prints a fixed readiness message and the operating system, current and home
/// directories, and executable argument to standard output.
func printStatus() {
    let info = ProcessInfo.processInfo
    let fm = FileManager.default
    print("AIUsage Windows build: ready")
    print("Operating system: \(info.operatingSystemVersionString)")
    print("Current directory: \(fm.currentDirectoryPath)")
    print("Home directory: \(fm.homeDirectoryForCurrentUser.path)")
    print("Executable: \(CommandLine.arguments.first ?? "AIUsageWindowsCLI")")
}

/// Prints the app version to standard output.
func printVersion() {
    print(version)
}

/// Prints selected Windows environment variables to standard output as `KEY=value`
/// lines, skipping variables that are not set.
func printEnv() {
    let keys = [
        "PROCESSOR_ARCHITECTURE",
        "PROCESSOR_IDENTIFIER",
        "USERPROFILE",
        "HOMEDRIVE",
        "HOMEPATH",
        "TEMP",
        "TMP",
        "APPDATA",
        "LOCALAPPDATA"
    ]

    for key in keys {
        if let value = ProcessInfo.processInfo.environment[key] {
            print("\(key)=\(value)")
        }
    }
}

/// Prints the app name, version, operating system, and current and home directories
/// to standard output as pretty-printed JSON with sorted keys.
/// Falls back to JSON containing only the app name and version if encoding or
/// UTF-8 conversion fails; encoding errors are caught.
func printJSON() {
    let summary = RuntimeSummary(
        appName: appName,
        version: version,
        operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
        currentDirectory: FileManager.default.currentDirectoryPath,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]

    if let jsonData = try? encoder.encode(summary),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        print(jsonString)
        return
    }

    print("{\"appName\":\"\(appName)\",\"version\":\"\(version)\"}")
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "status"

switch command {
case "status":
    printStatus()
case "version":
    printVersion()
case "help", "-h", "--help":
    printHelp()
case "env":
    printEnv()
case "json":
    printJSON()
default:
    print("Unknown command: \(command)")
    printHelp()
    Foundation.exit(2)
}