import Foundation
import MacNeutronCore

let executable = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
exit(await CommandLineTool.run(Array(CommandLine.arguments.dropFirst()),
                               environment: ProcessInfo.processInfo.environment,
                               executable: executable))
