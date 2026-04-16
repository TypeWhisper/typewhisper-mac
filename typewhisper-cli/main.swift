import Foundation

let args = CommandLine.arguments.dropFirst()

var portOverride: UInt16?
var jsonOutput = false
var devMode = false
var command: String?
var positionalArgs = [String]()

// Transcribe options
var languageOptions = CLITranscribeLanguageOptions()
var task: String?
var translateTo: String?
var engineOverride: String?
var modelOverride: String?
var awaitDownload = false

var argIterator = args.makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "--help", "-h":
        printUsage()
        exit(0)
    case "--version":
        printVersion()
        exit(0)
    case "--port":
        guard let next = argIterator.next(), let p = UInt16(next) else {
            printError("Error: --port requires a number.")
            exit(1)
        }
        portOverride = p
    case "--json":
        jsonOutput = true
    case "--dev":
        devMode = true
    case "--language":
        guard let next = argIterator.next() else {
            printError("Error: --language requires a value.")
            exit(1)
        }
        languageOptions.language = next
    case "--language-hint":
        guard let next = argIterator.next() else {
            printError("Error: --language-hint requires a value.")
            exit(1)
        }
        languageOptions.languageHints.append(next)
    case "--task":
        guard let next = argIterator.next() else {
            printError("Error: --task requires a value.")
            exit(1)
        }
        task = next
    case "--translate-to":
        guard let next = argIterator.next() else {
            printError("Error: --translate-to requires a value.")
            exit(1)
        }
        translateTo = next
    case "--engine":
        guard let next = argIterator.next() else {
            printError("Error: --engine requires a value.")
            exit(1)
        }
        engineOverride = next
    case "--model":
        guard let next = argIterator.next() else {
            printError("Error: --model requires a value.")
            exit(1)
        }
        modelOverride = next
    case "--await-download":
        awaitDownload = true
    default:
        // Ignore Apple/Xcode internal flags (e.g. -NSDocumentRevisionsDebugMode)
        if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") {
            _ = argIterator.next() // skip value if present
            continue
        }
        if arg.hasPrefix("-") && command != nil {
            printError("Error: Unknown option '\(arg)'.")
            exit(1)
        }
        if command == nil {
            command = arg
        } else {
            positionalArgs.append(arg)
        }
    }
}

if let validationError = languageOptions.validationError() {
    printError(validationError)
    exit(1)
}

guard let command else {
    printUsage()
    exit(1)
}

let port = portOverride ?? PortDiscovery.discoverPort(dev: devMode)
let client = CLIClient(port: port)

do {
    switch command {
    case "status":
        let data = try await client.status()
        print(OutputFormatter.formatStatus(data, json: jsonOutput))

    case "models":
        let data = try await client.models()
        print(OutputFormatter.formatModels(data, json: jsonOutput))

    case "transcribe":
        let fileURL: URL?
        if let path = positionalArgs.first, path != "-" {
            fileURL = URL(fileURLWithPath: path)
        } else {
            fileURL = nil // stdin
        }
        let data = try await client.transcribe(
            fileURL: fileURL,
            language: languageOptions.language,
            languageHints: languageOptions.languageHints,
            task: task,
            targetLanguage: translateTo,
            engine: engineOverride,
            model: modelOverride,
            awaitDownload: awaitDownload
        )
        print(OutputFormatter.formatTranscription(data, json: jsonOutput))

    default:
        printError("Error: Unknown command '\(command)'.")
        printUsage()
        exit(1)
    }
} catch let error as CLIError {
    printError(error.message)
    exit(error.exitCode)
} catch {
    printError("Error: \(error.localizedDescription)")
    exit(1)
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func printUsage() {
    let usage = """
        Usage: typewhisper <command> [options]

        Commands:
          transcribe <file>    Transcribe an audio file (or - for stdin)
          status               Show server status
          models               List available models

        Global options:
          --port <N>           Server port (default: auto-detect)
          --dev                Connect to TypeWhisper Dev instance
          --json               Output as JSON
          --help, -h           Show help
          --version            Show version

        Transcribe options:
          --language <code>    Source language (e.g. en, de)
          --language-hint <code>  Repeatable language hint for auto-detection
          --task <task>        transcribe (default) or translate
          --translate-to <code>  Target language for translation
          --engine <id>        Override the engine for this request (e.g. groq, qwen3)
          --model <id>         Override the model for this request (e.g. whisper-large-v3-turbo)
          --await-download     Wait for an engine to restore/download its model instead of failing with 409

        Examples:
          typewhisper status
          typewhisper transcribe recording.wav
          typewhisper transcribe recording.wav --language de --json
          typewhisper transcribe recording.wav --language-hint de --language-hint en
          typewhisper transcribe recording.wav --model whisper-large-v3-turbo
          typewhisper transcribe recording.wav --engine groq
          typewhisper transcribe recording.wav --engine groq --model whisper-large-v3-turbo
          typewhisper transcribe - < audio.wav
          cat audio.wav | typewhisper transcribe -
        """
    print(usage)
}

func printVersion() {
    print("typewhisper 0.9.2")
}
