#if os(macOS)
import Observation
import WorkLogCore

/// Owned by the main or panel controller, so replacing a SearchScreen preserves its context.
/// Contains ordinary records only. Secret queries, metadata, IDs and opened rows stay in the view.
@Observable @MainActor final class SearchSurfaceState {
    var scope: SearchScope = .all
    var recordQuery = ""
    var recordResults: [SearchHit] = []
    var recordSearchError: String?
    var selectedKey: SearchHitKey?
    var previewVisible = false
    var typeFilter: SearchSourceType?
    var projectFilterIds: [String] = []
    var tagFilterIds: [String] = []
    var filterRange: DateRange?
    var filterStart: WorkDate?
    var filterEnd: WorkDate?
    var useDates = false
    var filterError: String?
    var hasInitialized = false
}
#endif
