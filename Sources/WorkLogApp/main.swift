#if os(macOS)
import WorkLogCore
// TODO: macOS SwiftUI 앱 진입점
print("WorkLogApp")
#else
print("WorkLogApp은 macOS 전용입니다. Linux에서는 WorkLogCore와 worklog CLI만 빌드·테스트합니다.")
#endif
