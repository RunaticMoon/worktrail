#if os(macOS)
import SwiftUI
import WorkLogCore

/// Retain existing editing and task links behind the source-specific overview.
struct SourceActivityDetailSheet: View {
    @Bindable var model: MemoDetailModel
    let calendar: WorkCalendar
    let onClose: () -> Void
    let onSaved: () -> Void
    @State private var showsEditor = false

    var body: some View {
        if let record = model.importedActivity, !showsEditor {
            SourceActivityDetailView(record: record, calendar: calendar, onClose: onClose,
                                     onEdit: { showsEditor = true })
        } else {
            MemoDetailScreen(model: model, onClose: onClose, onSaved: onSaved)
        }
    }
}
#endif
