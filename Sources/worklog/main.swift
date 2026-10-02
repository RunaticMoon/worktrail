import Foundation
import WorkLogCore

// 개발용 worklog CLI 진입점. 인자를 WorkLogCLI로 넘기고 결과를 stdout/stderr로 출력한다.
// 모든 비즈니스 로직은 WorkLogCore.WorkLogCLI 안에 있다(테스트 가능하게).

let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment
let result = await WorkLogCLI.run(arguments, environment: environment)

if !result.stdout.isEmpty {
    FileHandle.standardOutput.write(Data(result.stdout.utf8))
}
if !result.stderr.isEmpty {
    FileHandle.standardError.write(Data(result.stderr.utf8))
}
exit(result.exitCode)
