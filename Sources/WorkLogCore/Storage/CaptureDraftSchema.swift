import Foundation

/// Receipts make ordinary capture submission durable across a failed checkpoint
/// cleanup. No Secret draft or AI/search input is stored in this table.
public enum CaptureDraftSchema {
    public static let v12 = """
    CREATE TABLE capture_draft_receipt (
        draft_id TEXT PRIMARY KEY,
        saved_at TEXT NOT NULL,
        remaining_checkpoint_json TEXT
    );
    """
}
