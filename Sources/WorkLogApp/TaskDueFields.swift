#if os(macOS)
import SwiftUI
import WorkLogCore

/// 새 업무와 상세 편집이 동일한 업무 시간대·알림 범위를 사용한다.
@MainActor struct TaskDueFields: View {
    @Binding var dueOn: WorkDate?
    @Binding var daysBefore: Int?
    let calendar: WorkCalendar
    let defaultDate: WorkDate
    var isCapture = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("마감일 설정", isOn: Binding(get: { dueOn != nil }, set: { setHasDueDate($0) }))
                    .dueFocus(isCapture, id: "dueToggle", order: 710) { setHasDueDate(dueOn == nil) }
                    .accessibilityIdentifier("task-due-enabled")
                if dueOn != nil {
                    DatePicker("마감일", selection: Binding(
                        get: { calendar.startOfDay(dueOn ?? defaultDate) },
                        set: { dueOn = calendar.workDate(of: $0) }), displayedComponents: .date)
                        .environment(\.calendar, calendar.calendar)
                        .environment(\.timeZone, calendar.timeZone)
                        .labelsHidden()
                        .dueFocus(isCapture, id: "dueDate", order: 711)
                        .accessibilityLabel("업무 마감일")
                        .accessibilityIdentifier("task-due-date")
                }
            }
            if dueOn != nil {
                Toggle("마감 알림", isOn: Binding(get: { daysBefore != nil }, set: { setHasReminder($0) }))
                    .dueFocus(isCapture, id: "dueReminderToggle", order: 712) { setHasReminder(daysBefore == nil) }
                    .accessibilityIdentifier("task-due-reminder-enabled")
                if let days = daysBefore {
                    Stepper(days == 0 ? "마감 당일부터" : "마감 \(days)일 전부터",
                            value: Binding(get: { daysBefore ?? 0 }, set: { daysBefore = $0 }), in: 0...365)
                        .dueFocus(isCapture, id: "dueReminderDays", order: 713)
                        .accessibilityLabel("마감 알림 시작일")
                        .accessibilityValue("마감 \(days)일 전부터")
                        .accessibilityIdentifier("task-due-reminder-days")
                    Text("마감 당일까지 매일 오전 9시 · \(calendar.timeZone.identifier). 완료·취소하면 알림이 멈춥니다.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func setHasDueDate(_ enabled: Bool) {
        dueOn = enabled ? (dueOn ?? defaultDate) : nil
        if !enabled, daysBefore != nil { daysBefore = nil }
    }

    private func setHasReminder(_ enabled: Bool) { daysBefore = enabled ? (daysBefore ?? 3) : nil }
}

private extension View {
    @ViewBuilder @MainActor func dueFocus(_ enabled: Bool, id: String, order: Int,
                                          action: (() -> Void)? = nil) -> some View {
        if enabled { captureFocus(id, order: order, action: action) }
        else { self }
    }
}
#endif
