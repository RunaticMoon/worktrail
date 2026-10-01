import Foundation

/// Secret 전용 DB(vault.sqlite). work.sqlite와 물리적으로 분리한다.
/// 평문은 저장하지 않는다: 본문·이전 버전·초안은 모두 AES-GCM 암호문(encrypted_payload)이다.
/// title/group은 잠금 중 제목 검색을 위한 최소 메타데이터이며 AI 경로에서 완전히 제외된다.
public enum VaultSchema {
    public static let migrations: [Migration] = [
        Migration(version: 1, sql: v1),
    ]

    static let v1 = """
    CREATE TABLE vault_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    -- key_version: 암호화 키 식별자(키 자체는 Keychain/KeyStore에만 있음)

    CREATE TABLE secret_group (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL UNIQUE
    );

    CREATE TABLE secret_item (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        group_id TEXT REFERENCES secret_group(id),
        latest_revision_id TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT
    );

    CREATE TABLE secret_revision (
        id TEXT PRIMARY KEY,
        secret_id TEXT NOT NULL REFERENCES secret_item(id) ON DELETE CASCADE,
        version INTEGER NOT NULL,
        key_version TEXT NOT NULL,
        encrypted_payload BLOB NOT NULL,
        created_at TEXT NOT NULL,
        UNIQUE(secret_id, version)
    );

    -- 잠금 해제 상태에서만 저장하는 암호화된 Secret 초안 (평문 초안 파일 없음)
    CREATE TABLE secret_draft (
        id TEXT PRIMARY KEY,
        key_version TEXT NOT NULL,
        encrypted_payload BLOB NOT NULL,
        updated_at TEXT NOT NULL
    );
    """
}
