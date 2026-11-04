import Foundation

public enum SchemaError: Error { case versionMismatch(Int, Int) }

public struct SchemaStep {
    public let version: Int
    public let sql: String
    public init(_ version: Int, _ sql: String) { self.version = version; self.sql = sql }
}

public enum Schema {
    /// Last shared integration-base step present on both this branch and the
    /// final macOS composition base (Token Saver economy credible_v4).
    public static let sharedIntegrationBaseVersion: Int = 56

    /// Named, relocatable checkpoint-list migration identity.
    ///
    /// Message body identity owns step 57, so this single checkpoint projection
    /// migration is composed atomically at step 58. Call sites and tests use
    /// this identity rather than a duplicated fixed SchemaStep.
    public static let checkpointListSchemaVersion: Int =
        sharedIntegrationBaseVersion + 2

    /// Must equal the highest SchemaStep version. Versions 63-66 were used by
    /// pre-release builds and must never be reused; v67 owns durable RCW1
    /// requests, v68 owns durable RCW1 assistant responses, v69 owns
    /// per-message Human/RCW1 display preferences, v70 owns the Bot
    /// control-plane identity tables, v71 owns per-Bot skill enablement,
    /// v72 owns content-free request-selection receipts, v73 admits
    /// winner selected_format rcs1, v74 owns content-free context-slot
    /// selection receipts for fresh-fallback seeds, and v75 owns Bot
    /// context-assembly receipts (bots branch used 72 before production
    /// shipped Token Saver receipts at that number), v76 owns Bot
    /// routine schedule spec (frequency, provider, model, reasoning),
    /// v77 owns nullable agent_runs.terminal_reason (downgrade-safe),
    /// v78 deduplicates Token Saver savings by logical request, v79 keeps
    /// authenticated item metadata outside the rolling replay window, and
    /// v80 owns host-authoritative Bot queued follow-ups, v81 indexes the
    /// exact running-thread predicate used by provider-session reaping, and
    /// v82 indexes audit_log(action, id) so the orchestration receipt poll
    /// can read its append signature without a table scan, v83 indexes
    /// agent_threads(workspace_id, updated_at DESC, id DESC) for the rail list,
    /// v84 adds agent_threads.reasoning_model, and v85 adds scheduled-task
    /// model fields, including repair for databases that already recorded v84,
    /// and v86 adds agent_threads.actor_json / actor_locked_at / execution_target,
    /// and v87 adds agent_threads.guest_runtime (bot agent runs inside its guest),
    /// and v88 adds Bot teams and group conversations plus
    /// bot_conversations.group_id (column added only when missing),
    /// and v89 adds bot_conversation_routing (per-conversation Bot desk route),
    /// and v92 adds per-Bot reply style columns on bots,
    /// and v93 adds the Titio notice ledger (titio_notices + titio_inbox_state).
    private static let scheduledTaskModelColumnsSchemaVersion = 85
    private static let threadActorSchemaVersion = 86
    private static let threadGuestRuntimeSchemaVersion = 87
    static let botTeamsGroupsSchemaVersion = 88
    static let botConversationRoutingSchemaVersion = 89
    /// v90 adds agent_threads.parent_thread_id / is_ephemeral for forked and side threads.
    static let threadForkColumnsSchemaVersion = 90
    /// v91 adds durable per-run result and read/acknowledgment projection.
    private static let agentRunResultsSchemaVersion = 91
    /// v92 adds per-Bot reply style: bots.reply_verbosity (human/verbose) and
    /// bots.caveman_enabled (on for every Bot except Titio).
    static let botReplyStyleSchemaVersion = 92
    /// v93 adds the Titio notice ledger: one durable row per host notice keyed by
    /// its source (exactly-once delivery across replays, producers and restarts)
    /// and the singleton inbox state (conversation id, unread, preview, armed reply).
    static let titioNoticesSchemaVersion = 93
    static let botContextsSchemaVersion = 94
    static let botConversationContextsSchemaVersion = 95
    static let botContextDelegationsSchemaVersion = 96
    static let hostRestoreQueueHoldsSchemaVersion = 97
    /// v98 adds device_trust.relay_public_key (X25519 key the paired device uses
    /// for the end-to-end relay channel).
    static let relayKeysSchemaVersion = 98
    /// v99 adds bots.sort_order (user drag order; NULL = never ordered).
    static let botSortOrderSchemaVersion = 99
    /// v100 stores every new-message run option on scheduled tasks (Ultracode,
    /// permission, plan mode, execution location and base branch).
    static let scheduledTaskRunOptionsSchemaVersion = 100
    static let virtualMachinesSchemaVersion = 101
    static let titioObservationSchemaVersion = 102
    /// v103 adds scheduled_tasks.max_concurrent_runs (per-task active-run limit).
    static let scheduledTaskConcurrencySchemaVersion = 103
    public static let currentVersion: Int = scheduledTaskConcurrencySchemaVersion

    /// SQL body for the named checkpoint-list migration (relocatable by version).
    public static let checkpointListMigrationSQL: String = """
        ALTER TABLE agent_turn_checkpoints ADD COLUMN files_summary_json TEXT NOT NULL DEFAULT '[]';
        ALTER TABLE agent_turn_checkpoints ADD COLUMN files_summary_truncated INTEGER NOT NULL DEFAULT 1;
        ALTER TABLE agent_turn_checkpoints ADD COLUMN list_turn_id TEXT NOT NULL DEFAULT '';
        ALTER TABLE agent_turn_checkpoints ADD COLUMN list_turn_id_encoded_bytes INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE agent_turn_checkpoints ADD COLUMN list_turn_id_sha256 TEXT;
        ALTER TABLE agent_turn_checkpoints ADD COLUMN list_turn_id_truncated INTEGER NOT NULL DEFAULT 1;
        ALTER TABLE agent_turn_checkpoints ADD COLUMN list_checkpoint_ref TEXT NOT NULL DEFAULT '';
        ALTER TABLE agent_turn_checkpoints ADD COLUMN list_checkpoint_ref_encoded_bytes INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE agent_turn_checkpoints ADD COLUMN list_checkpoint_ref_sha256 TEXT;
        ALTER TABLE agent_turn_checkpoints ADD COLUMN list_checkpoint_ref_truncated INTEGER NOT NULL DEFAULT 1;
        ALTER TABLE agent_turn_checkpoints ADD COLUMN list_error_message TEXT;
        ALTER TABLE agent_turn_checkpoints ADD COLUMN list_error_message_encoded_bytes INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE agent_turn_checkpoints ADD COLUMN list_error_message_sha256 TEXT;
        ALTER TABLE agent_turn_checkpoints ADD COLUMN list_error_message_truncated INTEGER NOT NULL DEFAULT 1;
        ALTER TABLE agent_turn_checkpoints ADD COLUMN list_completed_at TEXT NOT NULL DEFAULT '';
        ALTER TABLE agent_turn_checkpoints ADD COLUMN list_metadata_unavailable INTEGER NOT NULL DEFAULT 1;
        UPDATE agent_turn_checkpoints
        SET list_turn_id = 'rc2-legacy-row:' || lower(hex(randomblob(16))),
            list_completed_at = COALESCE(
                strftime('%Y-%m-%dT%H:%M:%fZ', completed_at),
                '1970-01-01T00:00:00.000Z'
            )
        WHERE list_metadata_unavailable = 1;
        CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_turn_checkpoints_list_keyset
            ON agent_turn_checkpoints(
                thread_id,
                checkpoint_turn_count,
                list_completed_at,
                list_turn_id
            );
        CREATE TABLE IF NOT EXISTS agent_turn_checkpoint_catalog_meta (
            thread_id TEXT PRIMARY KEY NOT NULL,
            revision INTEGER NOT NULL DEFAULT 1
        );
        CREATE TRIGGER IF NOT EXISTS trg_agent_turn_checkpoints_catalog_insert
        AFTER INSERT ON agent_turn_checkpoints
        BEGIN
            INSERT INTO agent_turn_checkpoint_catalog_meta(thread_id, revision)
            VALUES (NEW.thread_id, 2)
            ON CONFLICT(thread_id) DO UPDATE SET
                revision = agent_turn_checkpoint_catalog_meta.revision + 1;
        END;
        CREATE TRIGGER IF NOT EXISTS trg_agent_turn_checkpoints_catalog_update
        AFTER UPDATE ON agent_turn_checkpoints
        WHEN OLD.checkpoint_turn_count IS NOT NEW.checkpoint_turn_count
          OR OLD.status IS NOT NEW.status
          OR OLD.assistant_message_id IS NOT NEW.assistant_message_id
          OR OLD.files_summary_json IS NOT NEW.files_summary_json
          OR OLD.files_summary_truncated IS NOT NEW.files_summary_truncated
          OR OLD.list_turn_id IS NOT NEW.list_turn_id
          OR OLD.list_turn_id_encoded_bytes IS NOT NEW.list_turn_id_encoded_bytes
          OR OLD.list_turn_id_sha256 IS NOT NEW.list_turn_id_sha256
          OR OLD.list_turn_id_truncated IS NOT NEW.list_turn_id_truncated
          OR OLD.list_checkpoint_ref IS NOT NEW.list_checkpoint_ref
          OR OLD.list_checkpoint_ref_encoded_bytes IS NOT NEW.list_checkpoint_ref_encoded_bytes
          OR OLD.list_checkpoint_ref_sha256 IS NOT NEW.list_checkpoint_ref_sha256
          OR OLD.list_checkpoint_ref_truncated IS NOT NEW.list_checkpoint_ref_truncated
          OR OLD.list_error_message IS NOT NEW.list_error_message
          OR OLD.list_error_message_encoded_bytes IS NOT NEW.list_error_message_encoded_bytes
          OR OLD.list_error_message_sha256 IS NOT NEW.list_error_message_sha256
          OR OLD.list_error_message_truncated IS NOT NEW.list_error_message_truncated
          OR OLD.list_completed_at IS NOT NEW.list_completed_at
          OR OLD.list_metadata_unavailable IS NOT NEW.list_metadata_unavailable
          OR OLD.run_id IS NOT NEW.run_id
        BEGIN
            INSERT INTO agent_turn_checkpoint_catalog_meta(thread_id, revision)
            VALUES (NEW.thread_id, 2)
            ON CONFLICT(thread_id) DO UPDATE SET
                revision = agent_turn_checkpoint_catalog_meta.revision + 1;
        END;
        CREATE TRIGGER IF NOT EXISTS trg_agent_turn_checkpoints_catalog_delete
        AFTER DELETE ON agent_turn_checkpoints
        BEGIN
            INSERT INTO agent_turn_checkpoint_catalog_meta(thread_id, revision)
            VALUES (OLD.thread_id, 2)
            ON CONFLICT(thread_id) DO UPDATE SET
                revision = agent_turn_checkpoint_catalog_meta.revision + 1;
        END;
        """

    private static let scheduledTaskModelColumns: [(name: String, type: String)] = [
        ("reasoning_model", "TEXT"),
        ("distill_main_effort_json", "TEXT"),
        ("distill_reasoning_effort_json", "TEXT"),
    ]
    private static var scheduledTaskModelColumnsMigrationSQL: String {
        scheduledTaskModelColumns.map {
            "ALTER TABLE scheduled_tasks ADD COLUMN \($0.name) \($0.type);"
        }.joined(separator: "\n")
    }

    public static let steps: [SchemaStep] = [
        SchemaStep(1, """
        CREATE TABLE IF NOT EXISTS schema_meta (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            path TEXT NOT NULL,
            favorite INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS agent_threads (
            id TEXT PRIMARY KEY,
            project_id TEXT,
            workspace_id TEXT,
            title TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            provider_thread_id TEXT,
            status TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            diff_additions INTEGER NOT NULL DEFAULT 0,
            diff_deletions INTEGER NOT NULL DEFAULT 0,
            has_unread INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_agent_threads_project ON agent_threads(project_id);
        CREATE INDEX IF NOT EXISTS idx_agent_threads_workspace ON agent_threads(workspace_id);
        CREATE TABLE IF NOT EXISTS agent_messages (
            id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_agent_messages_thread ON agent_messages(thread_id);
        CREATE INDEX IF NOT EXISTS idx_agent_messages_thread_created_id ON agent_messages(thread_id, created_at, id);
        CREATE TABLE IF NOT EXISTS agent_runs (
            id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            status TEXT NOT NULL,
            started_at TEXT NOT NULL,
            finished_at TEXT,
            error_message TEXT,
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_agent_runs_thread ON agent_runs(thread_id);
        CREATE TABLE IF NOT EXISTS agent_stream_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            run_id TEXT NOT NULL,
            seq INTEGER NOT NULL,
            event_kind TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(run_id) REFERENCES agent_runs(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_stream_events_run ON agent_stream_events(run_id, seq);
        CREATE TABLE IF NOT EXISTS agent_turn_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            thread_id TEXT NOT NULL,
            run_id TEXT,
            turn_id TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_turn_snapshots_thread ON agent_turn_snapshots(thread_id);
        -- DEAD TABLE: workspace_selection
        -- No repository or call sites exist for this table beyond Bootstrap seeding.
        -- Candidate for removal in a future destructive migration once confirmed safe.
        -- Listed in Schema.knownDeadTableNames.
        CREATE TABLE IF NOT EXISTS workspace_selection (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            selected_workspace_id TEXT,
            selected_surface_id TEXT,
            selected_thread_id TEXT,
            selected_provider TEXT,
            selected_model TEXT,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS session_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            version INTEGER NOT NULL,
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        -- DEAD TABLE: terminal_sessions
        -- No repository or call sites reference this table; terminal output is
        -- stored in terminal_output_chunks (step 7) instead.
        -- Candidate for removal in a future destructive migration once confirmed safe.
        -- Listed in Schema.knownDeadTableNames.
        CREATE TABLE IF NOT EXISTS terminal_sessions (
            id TEXT PRIMARY KEY,
            surface_id TEXT NOT NULL,
            workspace_id TEXT,
            cwd TEXT,
            scrollback TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        -- DEAD TABLE: browser_profiles
        -- No repository or call sites reference this table; browser-profile
        -- management was never implemented in the current codebase.
        -- Candidate for removal in a future destructive migration once confirmed safe.
        -- Listed in Schema.knownDeadTableNames.
        CREATE TABLE IF NOT EXISTS browser_profiles (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            is_default INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            seq INTEGER NOT NULL,
            kind TEXT NOT NULL,
            request_id TEXT,
            origin_client_id TEXT,
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_events_seq ON events(seq);
        """),
        SchemaStep(2, """
        CREATE TABLE IF NOT EXISTS device_trust (
            id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            token_hash TEXT NOT NULL,
            created_at TEXT NOT NULL,
            last_seen_at TEXT,
            revoked_at TEXT,
            capabilities TEXT NOT NULL DEFAULT '*'
        );
        CREATE INDEX IF NOT EXISTS idx_device_trust_token ON device_trust(token_hash);
        CREATE TABLE IF NOT EXISTS pairing_codes (
            code TEXT PRIMARY KEY,
            created_at TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            redeemed_at TEXT,
            redeemed_device_id TEXT
        );
        CREATE TABLE IF NOT EXISTS audit_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            actor TEXT,
            action TEXT NOT NULL,
            detail TEXT
        );
        CREATE TABLE IF NOT EXISTS notifications (
            id TEXT PRIMARY KEY,
            workspace_id TEXT,
            surface_id TEXT,
            title TEXT NOT NULL,
            body TEXT,
            category TEXT,
            created_at TEXT NOT NULL,
            read_at TEXT,
            dismissed_at TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_notifications_workspace ON notifications(workspace_id);
        """),
        SchemaStep(3, """
        ALTER TABLE agent_threads ADD COLUMN color TEXT;
        """),
        SchemaStep(4, """
        CREATE TABLE IF NOT EXISTS pairing_requests (
            id TEXT PRIMARY KEY,
            code TEXT NOT NULL,
            device_name TEXT NOT NULL,
            created_at TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            device_id TEXT,
            decided_at TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_pairing_requests_status ON pairing_requests(status);
        """),
        SchemaStep(5, """
        ALTER TABLE agent_threads ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE agent_threads ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0;
        """),
        SchemaStep(6, """
        ALTER TABLE agent_threads ADD COLUMN permission_mode TEXT NOT NULL DEFAULT 'supervised';
        ALTER TABLE agent_threads ADD COLUMN reasoning_effort TEXT NOT NULL DEFAULT 'medium';
        """),
        SchemaStep(7, """
        CREATE TABLE IF NOT EXISTS terminal_output_chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            surface_id TEXT NOT NULL,
            workspace_id TEXT,
            chunk_index INTEGER NOT NULL,
            data BLOB NOT NULL,
            byte_count INTEGER NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_terminal_output_surface_index ON terminal_output_chunks(surface_id, chunk_index);
        CREATE INDEX IF NOT EXISTS idx_terminal_output_surface_id ON terminal_output_chunks(surface_id, id);
        """),
        SchemaStep(8, """
        CREATE TABLE IF NOT EXISTS provider_session_runtime (
            thread_id TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            provider_instance_id TEXT,
            status TEXT NOT NULL,
            resume_cursor TEXT,
            runtime_payload_json TEXT,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_provider_session_runtime_provider ON provider_session_runtime(provider, status);
        """),
        SchemaStep(9, """
        CREATE TABLE IF NOT EXISTS command_receipts (
            method TEXT NOT NULL,
            client_request_id TEXT NOT NULL,
            result_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY(method, client_request_id)
        );
        """),
        SchemaStep(10, """
        ALTER TABLE provider_session_runtime ADD COLUMN cwd TEXT;
        ALTER TABLE provider_session_runtime ADD COLUMN model TEXT;
        ALTER TABLE provider_session_runtime ADD COLUMN last_event_kind TEXT;
        ALTER TABLE provider_session_runtime ADD COLUMN last_error_message TEXT;
        """),
        SchemaStep(11, """
        CREATE TABLE IF NOT EXISTS provider_pending_callbacks (
            thread_id TEXT NOT NULL,
            request_id TEXT NOT NULL,
            callback_kind TEXT NOT NULL,
            state TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            resolved_at TEXT,
            stale_reason TEXT,
            PRIMARY KEY(thread_id, request_id, callback_kind),
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_provider_pending_callbacks_open ON provider_pending_callbacks(state, thread_id);
        """),
        SchemaStep(12, """
        CREATE TABLE IF NOT EXISTS agent_proposed_plans (
            thread_id TEXT NOT NULL,
            plan_id TEXT NOT NULL,
            turn_id TEXT,
            markdown TEXT NOT NULL,
            implemented_at TEXT,
            implementation_thread_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY(thread_id, plan_id),
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_agent_proposed_plans_thread ON agent_proposed_plans(thread_id, created_at);
        """),
        SchemaStep(13, """
        CREATE TABLE IF NOT EXISTS agent_turn_checkpoints (
            thread_id TEXT NOT NULL,
            run_id TEXT NOT NULL,
            turn_id TEXT NOT NULL,
            checkpoint_turn_count INTEGER NOT NULL,
            checkpoint_ref TEXT NOT NULL,
            status TEXT NOT NULL,
            files_json TEXT NOT NULL,
            assistant_message_id TEXT,
            error_message TEXT,
            completed_at TEXT NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY(thread_id, turn_id),
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE,
            FOREIGN KEY(run_id) REFERENCES agent_runs(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_agent_turn_checkpoints_thread ON agent_turn_checkpoints(thread_id, checkpoint_turn_count);
        """),
        SchemaStep(14, """
        ALTER TABLE agent_turn_checkpoints ADD COLUMN file_snapshots_json TEXT NOT NULL DEFAULT '[]';
        """),
        SchemaStep(15, """
        ALTER TABLE agent_turn_checkpoints ADD COLUMN diff_patch TEXT;
        ALTER TABLE agent_turn_checkpoints ADD COLUMN file_diffs_json TEXT NOT NULL DEFAULT '[]';
        """),
        SchemaStep(16, """
        ALTER TABLE agent_threads ADD COLUMN execution_mode TEXT NOT NULL DEFAULT 'local';
        ALTER TABLE agent_threads ADD COLUMN base_branch TEXT;
        ALTER TABLE agent_threads ADD COLUMN worktree_path TEXT;
        """),
        SchemaStep(17, """
        ALTER TABLE agent_threads ADD COLUMN service_tier TEXT NOT NULL DEFAULT 'auto';
        """),
        SchemaStep(18, """
        ALTER TABLE provider_session_runtime ADD COLUMN service_tier TEXT NOT NULL DEFAULT 'auto';
        """),
        SchemaStep(19, """
        ALTER TABLE provider_session_runtime ADD COLUMN runtime_mode TEXT NOT NULL DEFAULT 'supervised';
        """),
        SchemaStep(20, """
        ALTER TABLE provider_session_runtime ADD COLUMN adapter_key TEXT;
        ALTER TABLE provider_session_runtime ADD COLUMN binary_identity TEXT;
        """),
        SchemaStep(21, """
        ALTER TABLE agent_threads ADD COLUMN model_selection_json TEXT;
        """),
        SchemaStep(22, """
        ALTER TABLE agent_threads ADD COLUMN provider_instance_id TEXT;
        ALTER TABLE agent_runs ADD COLUMN provider_instance_id TEXT;
        """),
        SchemaStep(23, """
        CREATE TABLE IF NOT EXISTS agent_provider_event_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            thread_id TEXT NOT NULL,
            run_id TEXT,
            event_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            source TEXT NOT NULL,
            method TEXT NOT NULL,
            provider_turn_id TEXT,
            provider_item_id TEXT,
            provider_request_id TEXT,
            payload_json TEXT NOT NULL,
            received_at_ms INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE,
            FOREIGN KEY(run_id) REFERENCES agent_runs(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_provider_event_logs_thread ON agent_provider_event_logs(thread_id, id);
        CREATE INDEX IF NOT EXISTS idx_provider_event_logs_refs ON agent_provider_event_logs(provider_turn_id, provider_item_id, provider_request_id);
        """),
        SchemaStep(24, """
        CREATE TABLE IF NOT EXISTS agent_queued_messages (
            id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            text TEXT NOT NULL,
            attachments_json TEXT NOT NULL,
            interaction_mode TEXT NOT NULL,
            position INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_agent_queued_messages_thread ON agent_queued_messages(thread_id, position, created_at);
        """),
        SchemaStep(25, """
        CREATE TABLE IF NOT EXISTS token_saver_savings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            provider TEXT NOT NULL,
            mode TEXT NOT NULL,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            saved_tokens INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_savings_time ON token_saver_savings(created_at_ms);
        """),
        SchemaStep(26, """
        CREATE TABLE IF NOT EXISTS token_saver_savings_totals (
            provider TEXT NOT NULL,
            mode TEXT NOT NULL,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            saved_tokens INTEGER NOT NULL,
            runs INTEGER NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY(provider, mode)
        );
        INSERT INTO token_saver_savings_totals
            (provider, mode, input_tokens, output_tokens, saved_tokens, runs, updated_at)
        SELECT provider,
               mode,
               COALESCE(SUM(input_tokens), 0),
               COALESCE(SUM(output_tokens), 0),
               COALESCE(SUM(saved_tokens), 0),
               COUNT(*),
               COALESCE(MAX(created_at), strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        FROM token_saver_savings
        GROUP BY provider, mode
        ON CONFLICT(provider, mode) DO UPDATE SET
            input_tokens = token_saver_savings_totals.input_tokens + excluded.input_tokens,
            output_tokens = token_saver_savings_totals.output_tokens + excluded.output_tokens,
            saved_tokens = token_saver_savings_totals.saved_tokens + excluded.saved_tokens,
            runs = token_saver_savings_totals.runs + excluded.runs,
            updated_at = excluded.updated_at;
        """),
        SchemaStep(27, """
        CREATE TABLE IF NOT EXISTS rc_reversible_content (
            handle TEXT PRIMARY KEY,
            original BLOB NOT NULL,
            sha256 TEXT NOT NULL,
            byte_count INTEGER NOT NULL,
            ref_count INTEGER NOT NULL DEFAULT 0,
            created_at_ms INTEGER NOT NULL,
            last_access_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_rc_reversible_content_access ON rc_reversible_content(last_access_ms);
        """),
        SchemaStep(28, """
        ALTER TABLE token_saver_savings ADD COLUMN content_type TEXT NOT NULL DEFAULT 'unknown';
        ALTER TABLE token_saver_savings ADD COLUMN engine TEXT NOT NULL DEFAULT 'unknown';
        ALTER TABLE token_saver_savings ADD COLUMN cache_state TEXT NOT NULL DEFAULT 'unknown';
        """),
        SchemaStep(29, """
        ALTER TABLE device_trust ADD COLUMN client_device_id TEXT;
        ALTER TABLE device_trust ADD COLUMN always_allow_pairing INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE pairing_requests ADD COLUMN client_device_id TEXT;
        CREATE INDEX IF NOT EXISTS idx_device_trust_client_allow ON device_trust(client_device_id, always_allow_pairing);
        """),
        SchemaStep(30, """
        CREATE TABLE IF NOT EXISTS token_saver_encoder_manifests (
            role TEXT NOT NULL,
            model_id TEXT NOT NULL,
            source_url TEXT NOT NULL,
            revision TEXT NOT NULL,
            runtime TEXT NOT NULL,
            license TEXT NOT NULL,
            max_seq_len INTEGER NOT NULL,
            chunk_policy TEXT NOT NULL,
            manifest_json TEXT NOT NULL,
            installed_at TEXT NOT NULL,
            PRIMARY KEY(role, model_id)
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_encoder_manifests_role ON token_saver_encoder_manifests(role);
        """),
        SchemaStep(31, """
        CREATE TABLE IF NOT EXISTS shared_memory_blocks (
            id TEXT PRIMARY KEY,
            content_hash TEXT NOT NULL,
            reversible_handle TEXT NOT NULL,
            preview TEXT NOT NULL DEFAULT '',
            byte_count INTEGER NOT NULL,
            token_count_estimate INTEGER NOT NULL DEFAULT 0,
            ref_count INTEGER NOT NULL DEFAULT 0,
            metadata_json TEXT NOT NULL DEFAULT '{}',
            created_at_ms INTEGER NOT NULL,
            last_access_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_shared_memory_blocks_hash ON shared_memory_blocks(content_hash);
        CREATE INDEX IF NOT EXISTS idx_shared_memory_blocks_handle ON shared_memory_blocks(reversible_handle);
        CREATE INDEX IF NOT EXISTS idx_shared_memory_blocks_access ON shared_memory_blocks(last_access_ms);
        """),
        SchemaStep(32, """
        ALTER TABLE command_receipts ADD COLUMN owner_fingerprint TEXT;
        ALTER TABLE command_receipts ADD COLUMN params_hash TEXT;
        ALTER TABLE command_receipts ADD COLUMN state TEXT;
        ALTER TABLE command_receipts ADD COLUMN updated_at TEXT;
        """),
        SchemaStep(33, """
        ALTER TABLE command_receipts ADD COLUMN event_start_seq INTEGER;
        ALTER TABLE command_receipts ADD COLUMN event_end_seq INTEGER;
        DELETE FROM events WHERE rowid NOT IN (SELECT MIN(rowid) FROM events GROUP BY seq);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_events_unique_seq ON events(seq);
        CREATE TABLE IF NOT EXISTS event_sequence (
            singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
            last_seq INTEGER NOT NULL
        );
        INSERT OR IGNORE INTO event_sequence(singleton, last_seq)
        VALUES(1, (SELECT COALESCE(MAX(seq), 0) FROM events));
        UPDATE event_sequence
        SET last_seq = MAX(last_seq, (SELECT COALESCE(MAX(seq), 0) FROM events))
        WHERE singleton = 1;
        CREATE TABLE IF NOT EXISTS command_receipt_events (
            method TEXT NOT NULL,
            client_request_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            seq INTEGER NOT NULL UNIQUE,
            PRIMARY KEY(method, client_request_id, ordinal),
            FOREIGN KEY(method, client_request_id)
                REFERENCES command_receipts(method, client_request_id)
                ON DELETE CASCADE
        );
        """),
        SchemaStep(34, """
        ALTER TABLE agent_threads
        ADD COLUMN interaction_mode TEXT NOT NULL DEFAULT 'default';
        """),
        SchemaStep(35, """
        ALTER TABLE agent_messages
        ADD COLUMN attachments_json TEXT NOT NULL DEFAULT '[]';
        """),
        SchemaStep(36, """
        CREATE TABLE IF NOT EXISTS agent_thread_drafts (
            thread_id TEXT PRIMARY KEY,
            provider_instance_id TEXT NOT NULL,
            text TEXT NOT NULL DEFAULT '',
            attachments_json TEXT NOT NULL DEFAULT '[]',
            interaction_mode TEXT NOT NULL DEFAULT 'default',
            updated_at TEXT NOT NULL,
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        """),
        SchemaStep(37, """
        ALTER TABLE agent_queued_messages ADD COLUMN lease_id TEXT;
        ALTER TABLE agent_queued_messages ADD COLUMN lease_started_at TEXT;
        CREATE INDEX IF NOT EXISTS idx_agent_queued_messages_lease
        ON agent_queued_messages(thread_id, lease_id, lease_started_at, position, created_at);
        """),
        SchemaStep(38, """
        CREATE TABLE agent_thread_drafts_v38 (
            thread_id TEXT NOT NULL,
            provider_instance_id TEXT NOT NULL,
            text TEXT NOT NULL DEFAULT '',
            attachments_json TEXT NOT NULL DEFAULT '[]',
            interaction_mode TEXT NOT NULL DEFAULT 'default',
            updated_at TEXT NOT NULL,
            PRIMARY KEY(thread_id, provider_instance_id),
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        INSERT INTO agent_thread_drafts_v38(
            thread_id, provider_instance_id, text, attachments_json, interaction_mode, updated_at
        )
        SELECT thread_id, provider_instance_id, text, attachments_json, interaction_mode, updated_at
        FROM agent_thread_drafts;
        DROP TABLE agent_thread_drafts;
        ALTER TABLE agent_thread_drafts_v38 RENAME TO agent_thread_drafts;
        """),
        SchemaStep(39, """
        ALTER TABLE agent_queued_messages
        ADD COLUMN dispatch_state TEXT NOT NULL DEFAULT 'queued';
        ALTER TABLE agent_queued_messages
        ADD COLUMN dispatch_run_id TEXT;
        ALTER TABLE agent_queued_messages
        ADD COLUMN dispatch_updated_at TEXT;
        CREATE INDEX IF NOT EXISTS idx_agent_queued_messages_dispatch
        ON agent_queued_messages(thread_id, dispatch_state, position, created_at);
        """),
        SchemaStep(40, """
        CREATE TABLE IF NOT EXISTS agent_thread_fork_intents (
            child_thread_id TEXT PRIMARY KEY,
            source_thread_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            idempotency_key TEXT NOT NULL UNIQUE,
            state TEXT NOT NULL,
            child_thread_json TEXT NOT NULL,
            source_messages_json TEXT NOT NULL,
            provider_child_thread_id TEXT,
            last_error TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_agent_thread_fork_intents_state
        ON agent_thread_fork_intents(state, updated_at);
        """),
        SchemaStep(41, """
        ALTER TABLE provider_session_runtime ADD COLUMN last_run_id TEXT;
        """),
        SchemaStep(42, """
        CREATE TABLE IF NOT EXISTS agent_thread_undo_gc_pins (
            owner_id TEXT PRIMARY KEY,
            attachments_json TEXT NOT NULL DEFAULT '[]',
            opaque_payload TEXT NOT NULL DEFAULT '',
            expires_at TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_agent_thread_undo_gc_pins_expiry
        ON agent_thread_undo_gc_pins(expires_at);
        """),
        SchemaStep(43, """
        ALTER TABLE agent_threads
        ADD COLUMN run_as_user_json TEXT;
        """),
        SchemaStep(44, """
        CREATE TABLE IF NOT EXISTS scheduled_tasks (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            prompt TEXT NOT NULL,
            workspace_id TEXT NOT NULL,
            workspace_path_snapshot TEXT NOT NULL,
            run_as_user TEXT NOT NULL,
            run_as_uid INTEGER NOT NULL,
            provider TEXT NOT NULL,
            provider_instance_id TEXT NOT NULL,
            model TEXT NOT NULL,
            reasoning_effort TEXT NOT NULL,
            recurrence_json TEXT NOT NULL,
            timezone_id TEXT NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1,
            next_run_at TEXT,
            last_run_at TEXT,
            lease_owner TEXT,
            lease_expires_at TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_due
        ON scheduled_tasks(enabled, next_run_at, lease_expires_at);

        CREATE TABLE IF NOT EXISTS scheduled_task_runs (
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            occurrence_key TEXT NOT NULL UNIQUE,
            trigger TEXT NOT NULL,
            scheduled_at TEXT NOT NULL,
            queued_at TEXT NOT NULL,
            started_at TEXT,
            finished_at TEXT,
            status TEXT NOT NULL,
            thread_id TEXT,
            agent_run_id TEXT,
            error_code TEXT,
            error_summary TEXT,
            lease_owner TEXT,
            heartbeat_at TEXT,
            created_at TEXT NOT NULL,
            FOREIGN KEY(task_id) REFERENCES scheduled_tasks(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_scheduled_task_runs_task
        ON scheduled_task_runs(task_id, queued_at DESC);
        CREATE INDEX IF NOT EXISTS idx_scheduled_task_runs_status
        ON scheduled_task_runs(status, queued_at);
        """),
        SchemaStep(45, """
        CREATE TABLE IF NOT EXISTS token_saver_attempts (
            id TEXT PRIMARY KEY,
            run_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            adapter_version TEXT NOT NULL,
            provider_version TEXT NOT NULL,
            model TEXT NOT NULL,
            cache_state TEXT NOT NULL,
            language TEXT NOT NULL,
            hardware_class TEXT NOT NULL,
            workload TEXT NOT NULL,
            task_class TEXT NOT NULL,
            evidence_level TEXT NOT NULL,
            unavailable_fields_json TEXT NOT NULL DEFAULT '[]',
            created_at_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_attempts_run ON token_saver_attempts(run_id, created_at_ms);

        CREATE TABLE IF NOT EXISTS token_saver_attempt_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            attempt_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            FOREIGN KEY(attempt_id) REFERENCES token_saver_attempts(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_attempt_events_attempt ON token_saver_attempt_events(attempt_id, id);

        CREATE TABLE IF NOT EXISTS token_saver_input_components (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            attempt_id TEXT NOT NULL,
            category TEXT NOT NULL,
            tokens INTEGER NOT NULL,
            cost_micros INTEGER NOT NULL,
            created_at_ms INTEGER NOT NULL,
            FOREIGN KEY(attempt_id) REFERENCES token_saver_attempts(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_input_components_attempt ON token_saver_input_components(attempt_id, category);

        CREATE TABLE IF NOT EXISTS token_saver_recovery_objects (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            project_id TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            attempt_id TEXT NOT NULL,
            integrity_sha256 TEXT NOT NULL,
            original BLOB NOT NULL,
            byte_count INTEGER NOT NULL,
            state TEXT NOT NULL,
            expires_at_ms INTEGER,
            tombstoned_at_ms INTEGER,
            created_at_ms INTEGER NOT NULL,
            last_access_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_recovery_scope
        ON token_saver_recovery_objects(workspace_id, project_id, thread_id, provider, attempt_id);
        CREATE INDEX IF NOT EXISTS idx_token_saver_recovery_expiry
        ON token_saver_recovery_objects(expires_at_ms, tombstoned_at_ms);

        CREATE TABLE IF NOT EXISTS token_saver_recovery_capabilities (
            capability_hash TEXT PRIMARY KEY,
            object_id TEXT NOT NULL,
            revoked_at_ms INTEGER,
            created_at_ms INTEGER NOT NULL,
            FOREIGN KEY(object_id) REFERENCES token_saver_recovery_objects(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_recovery_capability_object
        ON token_saver_recovery_capabilities(object_id);

        CREATE TABLE IF NOT EXISTS token_saver_recovery_outbox (
            object_id TEXT PRIMARY KEY,
            state TEXT NOT NULL,
            transport_outcome TEXT NOT NULL,
            idempotency_key TEXT NOT NULL UNIQUE,
            updated_at_ms INTEGER NOT NULL,
            FOREIGN KEY(object_id) REFERENCES token_saver_recovery_objects(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS token_saver_recovery_references (
            id TEXT PRIMARY KEY,
            object_id TEXT NOT NULL,
            owner_kind TEXT NOT NULL,
            owner_id TEXT NOT NULL,
            expires_at_ms INTEGER,
            created_at_ms INTEGER NOT NULL,
            FOREIGN KEY(object_id) REFERENCES token_saver_recovery_objects(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_recovery_references_owner
        ON token_saver_recovery_references(owner_kind, owner_id);

        CREATE TABLE IF NOT EXISTS token_saver_lane_state (
            project_id TEXT NOT NULL,
            lane TEXT NOT NULL,
            state TEXT NOT NULL,
            reason TEXT NOT NULL,
            evidence_level TEXT NOT NULL,
            owner_role TEXT NOT NULL,
            permission_boundary TEXT NOT NULL,
            retention_days INTEGER NOT NULL,
            opted_out INTEGER NOT NULL,
            kill_switch_active INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            PRIMARY KEY(project_id, lane)
        );

        CREATE TABLE IF NOT EXISTS token_saver_owner_signoffs (
            role TEXT PRIMARY KEY,
            owner_name TEXT NOT NULL,
            signed_at_ms INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS token_saver_session_learn_records (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            project_id TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            attempt_id TEXT NOT NULL,
            text TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            expires_at_ms INTEGER,
            tombstoned_at_ms INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_session_learn_scope
        ON token_saver_session_learn_records(workspace_id, project_id, thread_id, provider, attempt_id);

        CREATE TABLE IF NOT EXISTS token_saver_rollover_capsules (
            id TEXT PRIMARY KEY,
            parent_thread_id TEXT NOT NULL,
            child_thread_id TEXT NOT NULL,
            scope_transition_json TEXT,
            capsule_sha256 TEXT NOT NULL,
            capsule_text TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS token_saver_audit_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_kind TEXT NOT NULL,
            project_id TEXT,
            thread_id TEXT,
            attempt_id TEXT,
            object_id TEXT,
            count_value INTEGER,
            reason TEXT,
            created_at_ms INTEGER NOT NULL
        );
        """),
        SchemaStep(46, """
        ALTER TABLE token_saver_recovery_objects
        ADD COLUMN operation_id TEXT;
        ALTER TABLE token_saver_recovery_objects
        ADD COLUMN lane TEXT NOT NULL DEFAULT 'semantic_prose';
        ALTER TABLE token_saver_session_learn_records
        ADD COLUMN lane TEXT NOT NULL DEFAULT 'session_learn';
        CREATE UNIQUE INDEX IF NOT EXISTS idx_token_saver_recovery_operation
        ON token_saver_recovery_objects(
            workspace_id, project_id, thread_id, provider, attempt_id, operation_id
        ) WHERE operation_id IS NOT NULL;
        """),
        SchemaStep(47, """
        ALTER TABLE token_saver_recovery_objects
        ADD COLUMN invocation_id TEXT;
        DROP INDEX IF EXISTS idx_token_saver_recovery_operation;
        CREATE UNIQUE INDEX IF NOT EXISTS idx_token_saver_recovery_invocation
        ON token_saver_recovery_objects(
            workspace_id, project_id, thread_id, provider, attempt_id, invocation_id
        ) WHERE invocation_id IS NOT NULL;

        ALTER TABLE token_saver_lane_state
        ADD COLUMN attribution_joined INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE token_saver_lane_state
        ADD COLUMN reconciliation_passed INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE token_saver_lane_state
        ADD COLUMN usage_semantics_available INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE token_saver_lane_state
        ADD COLUMN scorecard_id TEXT NOT NULL DEFAULT '';
        """),
        SchemaStep(48, """
        CREATE TABLE IF NOT EXISTS agent_thread_routing (
            thread_id TEXT PRIMARY KEY,
            mode TEXT NOT NULL CHECK(mode IN ('manual', 'auto')),
            configuration_json TEXT NOT NULL,
            revision INTEGER NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS agent_queued_message_routing (
            queued_message_id TEXT PRIMARY KEY,
            configuration_json TEXT NOT NULL,
            revision INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(queued_message_id) REFERENCES agent_queued_messages(id) ON DELETE CASCADE
        );
        """),
        SchemaStep(49, """
        ALTER TABLE agent_queued_message_routing ADD COLUMN deadline_at TEXT;
        ALTER TABLE agent_queued_message_routing ADD COLUMN budget_tokens INTEGER;
        ALTER TABLE agent_queued_message_routing ADD COLUMN budget_cost_micros INTEGER;
        ALTER TABLE agent_queued_message_routing ADD COLUMN reservation_id TEXT;
        ALTER TABLE agent_queued_message_routing ADD COLUMN reserved_tokens INTEGER;
        ALTER TABLE agent_queued_message_routing ADD COLUMN reserved_cost_micros INTEGER;
        ALTER TABLE agent_queued_message_routing ADD COLUMN admission_receipt_id TEXT;
        """),
        SchemaStep(50, """
        CREATE TABLE IF NOT EXISTS storage_usage_counters (
            storage_class TEXT PRIMARY KEY,
            payload_bytes INTEGER NOT NULL DEFAULT 0
        );
        INSERT OR REPLACE INTO storage_usage_counters(storage_class, payload_bytes)
        SELECT 'stream_events', COALESCE(SUM(
            LENGTH(CAST(event_kind AS BLOB)) + LENGTH(CAST(payload_json AS BLOB))
        ), 0) FROM agent_stream_events;
        INSERT OR REPLACE INTO storage_usage_counters(storage_class, payload_bytes)
        SELECT 'provider_logs', COALESCE(SUM(
            LENGTH(CAST(source AS BLOB)) + LENGTH(CAST(method AS BLOB)) + LENGTH(CAST(payload_json AS BLOB))
        ), 0) FROM agent_provider_event_logs;

        CREATE TRIGGER IF NOT EXISTS trg_stream_usage_insert
        AFTER INSERT ON agent_stream_events BEGIN
            UPDATE storage_usage_counters
            SET payload_bytes = payload_bytes + LENGTH(CAST(NEW.event_kind AS BLOB)) + LENGTH(CAST(NEW.payload_json AS BLOB))
            WHERE storage_class = 'stream_events';
        END;
        CREATE TRIGGER IF NOT EXISTS trg_stream_usage_delete
        AFTER DELETE ON agent_stream_events BEGIN
            UPDATE storage_usage_counters
            SET payload_bytes = MAX(0, payload_bytes - LENGTH(CAST(OLD.event_kind AS BLOB)) - LENGTH(CAST(OLD.payload_json AS BLOB)))
            WHERE storage_class = 'stream_events';
        END;
        CREATE TRIGGER IF NOT EXISTS trg_provider_usage_insert
        AFTER INSERT ON agent_provider_event_logs BEGIN
            UPDATE storage_usage_counters
            SET payload_bytes = payload_bytes + LENGTH(CAST(NEW.source AS BLOB)) + LENGTH(CAST(NEW.method AS BLOB)) + LENGTH(CAST(NEW.payload_json AS BLOB))
            WHERE storage_class = 'provider_logs';
        END;
        CREATE TRIGGER IF NOT EXISTS trg_provider_usage_delete
        AFTER DELETE ON agent_provider_event_logs BEGIN
            UPDATE storage_usage_counters
            SET payload_bytes = MAX(0, payload_bytes - LENGTH(CAST(OLD.source AS BLOB)) - LENGTH(CAST(OLD.method AS BLOB)) - LENGTH(CAST(OLD.payload_json AS BLOB)))
            WHERE storage_class = 'provider_logs';
        END;
        """),
        SchemaStep(51, """
        ALTER TABLE scheduled_tasks
        ADD COLUMN routing_mode TEXT NOT NULL DEFAULT 'manual'
            CHECK(routing_mode IN ('manual', 'auto'));
        """),
        // Repair factory deterministic_wrapper rows seeded with retention_days=0
        // (and kill_switch=1) before Token Saver store-before-loss could durable-
        // readback. INSERT OR IGNORE never upgrades those rows; without this
        // migration every ensureDefaults install stays permanently verbatim.
        SchemaStep(52, """
        UPDATE token_saver_lane_state
        SET retention_days = 7,
            kill_switch_active = 0
        WHERE lane = 'deterministic_wrapper'
          AND reason = 'owner_and_scorecard_required'
          AND opted_out = 0
          AND retention_days = 0
          AND kill_switch_active = 1;
        """),
        // Daily credible economy vs bare agent. Week UI = SUM(total_credible).
        // Past days without a row stay measured-only (no retroactive rewrite).
        SchemaStep(53, """
        CREATE TABLE IF NOT EXISTS token_saver_daily_economy (
            day_start_ms INTEGER PRIMARY KEY,
            measured_tokens INTEGER NOT NULL,
            dialect_tokens INTEGER NOT NULL,
            graphify_tokens INTEGER NOT NULL,
            orchestration_tokens INTEGER NOT NULL DEFAULT 0,
            total_credible INTEGER NOT NULL,
            window_usage_tokens INTEGER NOT NULL,
            formula_version TEXT NOT NULL,
            applied_output_share REAL NOT NULL,
            graphify_signal_count INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_daily_economy_updated
            ON token_saver_daily_economy(updated_at);
        """),
        // Measured Graphify CLI uses (query|path|explain) + exploration samples
        // for bare-user counterfactual. Not mixed into token_saver_savings pipes.
        SchemaStep(54, """
        CREATE TABLE IF NOT EXISTS graphify_usage_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at_ms INTEGER NOT NULL,
            provider TEXT NOT NULL,
            run_id TEXT NOT NULL,
            item_id TEXT NOT NULL,
            subcommand TEXT NOT NULL,
            answer_tokens INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL DEFAULT 'event_stream',
            ok INTEGER NOT NULL DEFAULT 0
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_graphify_usage_dedupe
            ON graphify_usage_events(run_id, item_id, subcommand);
        CREATE INDEX IF NOT EXISTS idx_graphify_usage_created
            ON graphify_usage_events(created_at_ms);
        CREATE INDEX IF NOT EXISTS idx_graphify_usage_ok_created
            ON graphify_usage_events(ok, created_at_ms);
        """),
        // Honesty axes for Token Saver savings: whether compressed bytes were
        // actually delivered, whether the row is prompt-bound, and a governance
        // snapshot. Additive only — defaults keep pre-migration rows unclassed.
        SchemaStep(55, """
        ALTER TABLE token_saver_savings ADD COLUMN attributability TEXT NOT NULL DEFAULT 'unknown';
        ALTER TABLE token_saver_savings ADD COLUMN delivered INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE token_saver_savings ADD COLUMN governance_json TEXT NOT NULL DEFAULT '{}';
        ALTER TABLE token_saver_savings_totals ADD COLUMN attributability TEXT NOT NULL DEFAULT 'unknown';
        ALTER TABLE token_saver_savings_totals ADD COLUMN delivered INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE token_saver_savings_totals ADD COLUMN governance_json TEXT NOT NULL DEFAULT '{}';
        """),
        // credible_v4 evidence: keep the pre-cap estimated legs and the cap that actually
        // bound the result, plus the billed-unit window the caps were computed against.
        // WHY: credible_v3 stored only the post-cap number, so a collapse (estimate scaled
        // down by orders of magnitude) was indistinguishable from a genuinely small day.
        SchemaStep(56, """
        ALTER TABLE token_saver_daily_economy ADD COLUMN dialect_raw_tokens INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE token_saver_daily_economy ADD COLUMN graphify_raw_tokens INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE token_saver_daily_economy ADD COLUMN cap_binding TEXT NOT NULL DEFAULT 'none';
        ALTER TABLE token_saver_daily_economy ADD COLUMN window_usage_billed_units REAL NOT NULL DEFAULT 0;
        """),
        // Frozen identity for bounded agent.message.get pagination. New writes
        // materialize these fields once. Existing rows are materialized on their
        // first offset-zero read because stock SQLite has no SHA-256 function.
        // The trigger catches every direct content mutator (including Token
        // Saver capsule cleanup), invalidates the digest, and advances revision
        // so a client can never splice chunks from two bodies.
        SchemaStep(57, """
        ALTER TABLE agent_messages ADD COLUMN body_sha256 TEXT;
        ALTER TABLE agent_messages ADD COLUMN body_bytes INTEGER;
        ALTER TABLE agent_messages ADD COLUMN body_revision INTEGER NOT NULL DEFAULT 1;
        CREATE TRIGGER IF NOT EXISTS trg_agent_message_body_identity_update
        AFTER UPDATE OF content ON agent_messages
        WHEN NEW.content IS NOT OLD.content
             AND NEW.body_revision = OLD.body_revision
        BEGIN
            UPDATE agent_messages
            SET body_sha256 = NULL,
                body_bytes = length(CAST(NEW.content AS BLOB)),
                body_revision = OLD.body_revision + 1
            WHERE id = NEW.id;
        END;
        """),
        // ONE named relocatable step: mobile list projection + keyset +
        // per-thread catalog revision. Renumber via `checkpointListSchemaVersion`
        // only — never duplicate this SQL as a second fixed SchemaStep.
        SchemaStep(checkpointListSchemaVersion, checkpointListMigrationSQL),
        // Per-thread savings attribution so Agent final replies can show
        // "You saved N tokens in this thread" from the local ledger.
        // Event rows keep thread_id for windowed reports; the permanent
        // thread_totals table survives event prune so multi-week threads
        // still show an honest cumulative total.
        SchemaStep(59, """
        ALTER TABLE token_saver_savings ADD COLUMN thread_id TEXT NOT NULL DEFAULT '';
        CREATE INDEX IF NOT EXISTS idx_token_saver_savings_thread
            ON token_saver_savings(thread_id, created_at_ms);
        CREATE TABLE IF NOT EXISTS token_saver_thread_totals (
            thread_id TEXT PRIMARY KEY NOT NULL,
            saved_tokens INTEGER NOT NULL,
            runs INTEGER NOT NULL,
            updated_at TEXT NOT NULL
        );
        """),
        // v60 never shipped. Historical payload maintenance cannot run as a
        // schema step because that would make launch one corpus-sized write.
        // Keep the version slot monotonic while the bounded resumable worker
        // owns cleanup after bootstrap.
        SchemaStep(60, """
        SELECT 1;
        """),
        // Some pre-release databases already recorded v60. Install lifecycle
        // evidence and child-delete behavior forward-only so those databases
        // recover through the same bounded maintenance predicates.
        SchemaStep(61, """
        ALTER TABLE agent_thread_fork_intents
        ADD COLUMN provider_creation_attempted INTEGER NOT NULL DEFAULT 1;
        CREATE TRIGGER IF NOT EXISTS trg_agent_thread_fork_intent_delete_local_committed_child
        AFTER DELETE ON agent_threads
        BEGIN
            DELETE FROM agent_thread_fork_intents
            WHERE child_thread_id = OLD.id
              AND state = 'local_committed';
        END;
        """),
        SchemaStep(62, """
        CREATE INDEX IF NOT EXISTS idx_agent_thread_fork_intents_maintenance
            ON agent_thread_fork_intents(
                updated_at,
                child_thread_id
            )
            WHERE state = 'local_committed'
               OR state = 'compensated'
               OR state = 'abandoned';
        """),
        // Durable human -> RCW1 disclosure belongs to the retained user message,
        // not the evictable provider stream. The FK keeps storage bounded by the
        // existing 100-message transcript window and removes rows on prune/delete.
        SchemaStep(67, """
        CREATE TABLE IF NOT EXISTS agent_message_rcw1_requests (
            message_id TEXT PRIMARY KEY NOT NULL,
            wire_request_text TEXT NOT NULL,
            protocol_version TEXT NOT NULL CHECK(protocol_version = 'RCW1'),
            created_at TEXT NOT NULL,
            FOREIGN KEY(message_id) REFERENCES agent_messages(id) ON DELETE CASCADE
        );
        """),
        // Durable RCW1 -> human disclosure belongs to the canonical retained
        // assistant message. Stream events are capped and cannot be the owner of
        // exact provider bytes across event pruning or app relaunch. run_id and
        // turn_id provide identity-safe timeline association without comparing
        // response text (two turns may legitimately return identical prose).
        SchemaStep(68, """
        CREATE TABLE IF NOT EXISTS agent_message_rcw1_responses (
            message_id TEXT PRIMARY KEY NOT NULL,
            run_id TEXT NOT NULL,
            turn_id TEXT NOT NULL CHECK(length(trim(turn_id)) > 0),
            wire_response_text TEXT NOT NULL,
            protocol_version TEXT NOT NULL CHECK(protocol_version = 'RCW1'),
            created_at TEXT NOT NULL,
            FOREIGN KEY(message_id) REFERENCES agent_messages(id) ON DELETE CASCADE
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_message_rcw1_responses_run
            ON agent_message_rcw1_responses(run_id);
        CREATE INDEX IF NOT EXISTS idx_agent_message_rcw1_responses_turn
            ON agent_message_rcw1_responses(turn_id);
        """),
        // Canonical transcript messages own their display choice. Absence means
        // Human; the repository deletes default rows. The FK bounds preferences
        // by live messages and preserves exact state through relational Undo.
        SchemaStep(69, """
        CREATE TABLE IF NOT EXISTS agent_message_token_saver_display_preferences (
            message_id TEXT PRIMARY KEY NOT NULL,
            display_mode TEXT NOT NULL CHECK(display_mode IN ('human', 'rcw1')),
            updated_at TEXT NOT NULL,
            FOREIGN KEY(message_id) REFERENCES agent_messages(id) ON DELETE CASCADE
        );
        """),
        // Durable named teammate identity. A Bot is not an AgentThread.
        // Versions 63-66 are retired and must never be reused.
        SchemaStep(70, """
        CREATE TABLE IF NOT EXISTS bots (
            id TEXT PRIMARY KEY NOT NULL,
            handle TEXT NOT NULL,
            name TEXT NOT NULL,
            title TEXT NOT NULL,
            description TEXT NOT NULL,
            avatar_symbol TEXT NOT NULL,
            pinned INTEGER NOT NULL DEFAULT 0,
            hidden INTEGER NOT NULL DEFAULT 0,
            current_revision_id TEXT,
            directory_epoch INTEGER NOT NULL DEFAULT 1,
            notifications_enabled INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            deleted_at TEXT,
            workspace_id TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_bots_updated
            ON bots(updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_bots_live
            ON bots(deleted_at, hidden, updated_at DESC);

        CREATE TABLE IF NOT EXISTS bot_revisions (
            id TEXT PRIMARY KEY NOT NULL,
            bot_id TEXT NOT NULL,
            revision_number INTEGER NOT NULL,
            name TEXT NOT NULL,
            title TEXT NOT NULL,
            description TEXT NOT NULL,
            soul TEXT NOT NULL DEFAULT '',
            provider TEXT NOT NULL,
            provider_instance_id TEXT NOT NULL,
            model TEXT NOT NULL,
            reasoning_effort TEXT NOT NULL,
            compatible_route_set_json TEXT NOT NULL,
            permission_mode TEXT NOT NULL,
            desktop_kind TEXT NOT NULL,
            digest TEXT NOT NULL,
            published_at TEXT NOT NULL,
            supersedes_revision_id TEXT,
            FOREIGN KEY(bot_id) REFERENCES bots(id),
            UNIQUE(bot_id, revision_number)
        );
        CREATE INDEX IF NOT EXISTS idx_bot_revisions_bot
            ON bot_revisions(bot_id, revision_number);

        CREATE TABLE IF NOT EXISTS bot_handles (
            handle TEXT PRIMARY KEY NOT NULL,
            bot_id TEXT NOT NULL UNIQUE,
            created_at TEXT NOT NULL,
            FOREIGN KEY(bot_id) REFERENCES bots(id)
        );

        CREATE TABLE IF NOT EXISTS bot_handle_tombstones (
            handle TEXT PRIMARY KEY NOT NULL,
            bot_id TEXT NOT NULL,
            deleted_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS bot_conversations (
            id TEXT PRIMARY KEY NOT NULL,
            bot_id TEXT NOT NULL,
            title TEXT NOT NULL,
            pinned INTEGER NOT NULL DEFAULT 0,
            hidden INTEGER NOT NULL DEFAULT 0,
            unread INTEGER NOT NULL DEFAULT 0,
            attention_state TEXT NOT NULL DEFAULT 'none',
            linked_agent_thread_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(bot_id) REFERENCES bots(id)
        );
        CREATE INDEX IF NOT EXISTS idx_bot_conversations_bot
            ON bot_conversations(bot_id, updated_at DESC);

        CREATE TABLE IF NOT EXISTS bot_memory_items (
            id TEXT PRIMARY KEY NOT NULL,
            bot_id TEXT NOT NULL,
            current_revision_id TEXT,
            forgotten_at TEXT,
            expires_at TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(bot_id) REFERENCES bots(id)
        );
        CREATE INDEX IF NOT EXISTS idx_bot_memory_bot
            ON bot_memory_items(bot_id, updated_at DESC);

        CREATE TABLE IF NOT EXISTS bot_memory_item_revisions (
            id TEXT PRIMARY KEY NOT NULL,
            item_id TEXT NOT NULL,
            bot_id TEXT NOT NULL,
            revision_number INTEGER NOT NULL,
            content TEXT NOT NULL,
            provenance TEXT NOT NULL DEFAULT '',
            trusted INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            supersedes_revision_id TEXT,
            FOREIGN KEY(item_id) REFERENCES bot_memory_items(id),
            UNIQUE(item_id, revision_number)
        );
        CREATE INDEX IF NOT EXISTS idx_bot_memory_revisions_item
            ON bot_memory_item_revisions(item_id, revision_number);

        CREATE TABLE IF NOT EXISTS bot_attention_items (
            id TEXT PRIMARY KEY NOT NULL,
            bot_id TEXT NOT NULL,
            conversation_id TEXT,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            detail TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            acknowledged_at TEXT,
            FOREIGN KEY(bot_id) REFERENCES bots(id)
        );
        CREATE INDEX IF NOT EXISTS idx_bot_attention_created
            ON bot_attention_items(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_bot_attention_open
            ON bot_attention_items(acknowledged_at, created_at DESC);

        CREATE TABLE IF NOT EXISTS bot_routine_definitions (
            id TEXT PRIMARY KEY NOT NULL,
            bot_id TEXT NOT NULL,
            name TEXT NOT NULL,
            prompt TEXT NOT NULL,
            schedule_note TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(bot_id) REFERENCES bots(id)
        );
        CREATE INDEX IF NOT EXISTS idx_bot_routines_bot
            ON bot_routine_definitions(bot_id);

        CREATE TABLE IF NOT EXISTS bot_routine_activations (
            routine_id TEXT PRIMARY KEY NOT NULL,
            bot_id TEXT NOT NULL,
            is_enabled INTEGER NOT NULL DEFAULT 0,
            last_test_run_requested_at TEXT,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(routine_id) REFERENCES bot_routine_definitions(id),
            FOREIGN KEY(bot_id) REFERENCES bots(id)
        );
        """),
        // Per-Bot skill enablement. Duplicate must copy these; they are not
        // conversation memory and they are not filesystem paths.
        SchemaStep(71, """
        CREATE TABLE IF NOT EXISTS bot_skill_bindings (
            bot_id TEXT NOT NULL,
            skill_id TEXT NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1,
            digest TEXT,
            updated_at TEXT NOT NULL,
            PRIMARY KEY(bot_id, skill_id),
            FOREIGN KEY(bot_id) REFERENCES bots(id)
        );
        CREATE INDEX IF NOT EXISTS idx_bot_skill_bindings_bot
            ON bot_skill_bindings(bot_id, enabled);
        """),
        // Content-free request-selection receipts. Winner rows never store
        // source/payload/handle/ABI/envelope SHA or a billing claim. Arms
        // always include Human, RCW1, and RCS1; RCS1 is non-selectable.
        SchemaStep(72, """
        CREATE TABLE IF NOT EXISTS token_saver_run_winner_receipts (
            run_id TEXT PRIMARY KEY NOT NULL,
            thread_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            resolved_model TEXT NOT NULL,
            selected_format TEXT NOT NULL CHECK(selected_format IN ('human', 'rcw1')),
            reason TEXT NOT NULL CHECK(reason IN (
                'unique_strict_minimum',
                'human_lowest_cost',
                'tie',
                'no_eligible_optimized_candidate',
                'counter_unavailable',
                'counter_uncertain',
                'counter_error',
                'counter_binding_mismatch',
                'candidate_error',
                'candidate_unknown',
                'invalid_measurement'
            )),
            modeled_context_delta INTEGER NOT NULL CHECK(modeled_context_delta >= 0),
            counter_id TEXT,
            counter_revision TEXT,
            encoding TEXT,
            counter_status TEXT NOT NULL CHECK(counter_status IN (
                'exact_local_tokenizer',
                'exact_resolved_model_tokenizer',
                'unavailable',
                'uncertain',
                'error',
                'binding_mismatch'
            )),
            lifecycle TEXT NOT NULL CHECK(lifecycle IN (
                'provisional',
                'delivered',
                'not_delivered',
                'delivery_unknown'
            )),
            billing_claim INTEGER NOT NULL CHECK(billing_claim = 0),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(run_id) REFERENCES agent_runs(id) ON DELETE CASCADE,
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE,
            CHECK(
                (
                    counter_status IN (
                        'exact_local_tokenizer',
                        'exact_resolved_model_tokenizer'
                    )
                    AND counter_id IS NOT NULL
                    AND counter_revision IS NOT NULL
                    AND encoding IS NOT NULL
                )
                OR
                (
                    counter_status NOT IN (
                        'exact_local_tokenizer',
                        'exact_resolved_model_tokenizer'
                    )
                    AND counter_id IS NULL
                    AND counter_revision IS NULL
                    AND encoding IS NULL
                )
            )
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_run_winner_receipts_thread
            ON token_saver_run_winner_receipts(thread_id);
        CREATE INDEX IF NOT EXISTS idx_token_saver_run_winner_receipts_provisional
            ON token_saver_run_winner_receipts(lifecycle)
            WHERE lifecycle = 'provisional';
        CREATE TABLE IF NOT EXISTS token_saver_run_arm_receipts (
            run_id TEXT NOT NULL,
            format TEXT NOT NULL CHECK(format IN ('human', 'rcw1', 'rcs1')),
            source_bound INTEGER NOT NULL CHECK(source_bound IN (0, 1)),
            producer_id TEXT NOT NULL,
            producer_revision TEXT NOT NULL,
            abi_revision TEXT NOT NULL,
            generation TEXT NOT NULL CHECK(generation IN ('passed', 'failed', 'unknown', 'not_required')),
            structural TEXT NOT NULL CHECK(structural IN ('passed', 'failed', 'unknown', 'not_required')),
            semantic TEXT NOT NULL CHECK(semantic IN ('passed', 'failed', 'unknown', 'not_required')),
            recovery TEXT NOT NULL CHECK(recovery IN ('passed', 'failed', 'unknown', 'not_required')),
            projection TEXT NOT NULL CHECK(projection IN ('projected', 'not_projected', 'unknown')),
            availability TEXT NOT NULL CHECK(availability IN ('available', 'unavailable', 'unknown')),
            eligible INTEGER NOT NULL CHECK(eligible IN (0, 1)),
            proven_effective_count INTEGER
                CHECK(proven_effective_count IS NULL OR proven_effective_count >= 0),
            PRIMARY KEY(run_id, format),
            FOREIGN KEY(run_id) REFERENCES token_saver_run_winner_receipts(run_id)
                ON DELETE CASCADE
        );
        """),
        // Admit winner selected_format rcs1. SQLite cannot alter a CHECK, so
        // rebuild both receipt tables inside the migrator transaction and copy
        // every existing row first.
        SchemaStep(73, """
        CREATE TABLE token_saver_run_winner_receipts_v73 (
            run_id TEXT PRIMARY KEY NOT NULL,
            thread_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            resolved_model TEXT NOT NULL,
            selected_format TEXT NOT NULL CHECK(selected_format IN ('human', 'rcw1', 'rcs1')),
            reason TEXT NOT NULL CHECK(reason IN (
                'unique_strict_minimum',
                'human_lowest_cost',
                'tie',
                'no_eligible_optimized_candidate',
                'counter_unavailable',
                'counter_uncertain',
                'counter_error',
                'counter_binding_mismatch',
                'candidate_error',
                'candidate_unknown',
                'invalid_measurement'
            )),
            modeled_context_delta INTEGER NOT NULL CHECK(modeled_context_delta >= 0),
            counter_id TEXT,
            counter_revision TEXT,
            encoding TEXT,
            counter_status TEXT NOT NULL CHECK(counter_status IN (
                'exact_local_tokenizer',
                'exact_resolved_model_tokenizer',
                'unavailable',
                'uncertain',
                'error',
                'binding_mismatch'
            )),
            lifecycle TEXT NOT NULL CHECK(lifecycle IN (
                'provisional',
                'delivered',
                'not_delivered',
                'delivery_unknown'
            )),
            billing_claim INTEGER NOT NULL CHECK(billing_claim = 0),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(run_id) REFERENCES agent_runs(id) ON DELETE CASCADE,
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE,
            CHECK(
                (
                    counter_status IN (
                        'exact_local_tokenizer',
                        'exact_resolved_model_tokenizer'
                    )
                    AND counter_id IS NOT NULL
                    AND counter_revision IS NOT NULL
                    AND encoding IS NOT NULL
                )
                OR
                (
                    counter_status NOT IN (
                        'exact_local_tokenizer',
                        'exact_resolved_model_tokenizer'
                    )
                    AND counter_id IS NULL
                    AND counter_revision IS NULL
                    AND encoding IS NULL
                )
            )
        );
        INSERT INTO token_saver_run_winner_receipts_v73
        SELECT
            run_id, thread_id, provider, resolved_model, selected_format, reason,
            modeled_context_delta, counter_id, counter_revision, encoding,
            counter_status, lifecycle, billing_claim, created_at, updated_at
        FROM token_saver_run_winner_receipts;
        CREATE TABLE token_saver_run_arm_receipts_v73 (
            run_id TEXT NOT NULL,
            format TEXT NOT NULL CHECK(format IN ('human', 'rcw1', 'rcs1')),
            source_bound INTEGER NOT NULL CHECK(source_bound IN (0, 1)),
            producer_id TEXT NOT NULL,
            producer_revision TEXT NOT NULL,
            abi_revision TEXT NOT NULL,
            generation TEXT NOT NULL CHECK(generation IN ('passed', 'failed', 'unknown', 'not_required')),
            structural TEXT NOT NULL CHECK(structural IN ('passed', 'failed', 'unknown', 'not_required')),
            semantic TEXT NOT NULL CHECK(semantic IN ('passed', 'failed', 'unknown', 'not_required')),
            recovery TEXT NOT NULL CHECK(recovery IN ('passed', 'failed', 'unknown', 'not_required')),
            projection TEXT NOT NULL CHECK(projection IN ('projected', 'not_projected', 'unknown')),
            availability TEXT NOT NULL CHECK(availability IN ('available', 'unavailable', 'unknown')),
            eligible INTEGER NOT NULL CHECK(eligible IN (0, 1)),
            proven_effective_count INTEGER
                CHECK(proven_effective_count IS NULL OR proven_effective_count >= 0),
            PRIMARY KEY(run_id, format),
            FOREIGN KEY(run_id) REFERENCES token_saver_run_winner_receipts_v73(run_id)
                ON DELETE CASCADE
        );
        INSERT INTO token_saver_run_arm_receipts_v73
        SELECT
            run_id, format, source_bound, producer_id, producer_revision,
            abi_revision, generation, structural, semantic, recovery,
            projection, availability, eligible, proven_effective_count
        FROM token_saver_run_arm_receipts;
        DROP TABLE token_saver_run_arm_receipts;
        DROP TABLE token_saver_run_winner_receipts;
        ALTER TABLE token_saver_run_winner_receipts_v73 RENAME TO token_saver_run_winner_receipts;
        ALTER TABLE token_saver_run_arm_receipts_v73 RENAME TO token_saver_run_arm_receipts;
        CREATE INDEX IF NOT EXISTS idx_token_saver_run_winner_receipts_thread
            ON token_saver_run_winner_receipts(thread_id);
        CREATE INDEX IF NOT EXISTS idx_token_saver_run_winner_receipts_provisional
            ON token_saver_run_winner_receipts(lifecycle)
            WHERE lifecycle = 'provisional';
        """),
        // Content-free context-slot receipts for one fresh-fallback seed.
        // Identity is (run, destination provider thread, snapshot digest,
        // source message, ordinal). Rows never store payload/handle/ABI.
        SchemaStep(74, """
        CREATE TABLE IF NOT EXISTS token_saver_context_slot_receipts (
            run_id TEXT NOT NULL,
            destination_provider_thread_id TEXT NOT NULL,
            snapshot_digest TEXT NOT NULL,
            source_message_id TEXT NOT NULL,
            role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
            ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
            provider TEXT NOT NULL,
            resolved_model TEXT NOT NULL,
            selected_format TEXT NOT NULL CHECK(selected_format IN ('human', 'rcw1', 'rcs1')),
            reason TEXT NOT NULL CHECK(reason IN (
                'unique_strict_minimum',
                'human_lowest_cost',
                'tie',
                'no_eligible_optimized_candidate',
                'counter_unavailable',
                'counter_uncertain',
                'counter_error',
                'counter_binding_mismatch',
                'candidate_error',
                'candidate_unknown',
                'invalid_measurement'
            )),
            modeled_context_delta INTEGER NOT NULL CHECK(modeled_context_delta >= 0),
            counter_id TEXT,
            counter_revision TEXT,
            encoding TEXT,
            counter_status TEXT NOT NULL CHECK(counter_status IN (
                'exact_local_tokenizer',
                'exact_resolved_model_tokenizer',
                'unavailable',
                'uncertain',
                'error',
                'binding_mismatch'
            )),
            lifecycle TEXT NOT NULL CHECK(lifecycle IN (
                'provisional',
                'delivered',
                'not_delivered',
                'delivery_unknown'
            )),
            billing_claim INTEGER NOT NULL CHECK(billing_claim = 0),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY(
                run_id,
                destination_provider_thread_id,
                snapshot_digest,
                source_message_id,
                ordinal
            ),
            FOREIGN KEY(run_id) REFERENCES agent_runs(id) ON DELETE CASCADE,
            CHECK(
                (
                    counter_status IN (
                        'exact_local_tokenizer',
                        'exact_resolved_model_tokenizer'
                    )
                    AND counter_id IS NOT NULL
                    AND counter_revision IS NOT NULL
                    AND encoding IS NOT NULL
                )
                OR
                (
                    counter_status NOT IN (
                        'exact_local_tokenizer',
                        'exact_resolved_model_tokenizer'
                    )
                    AND counter_id IS NULL
                    AND counter_revision IS NULL
                    AND encoding IS NULL
                )
            )
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_context_slot_receipts_run
            ON token_saver_context_slot_receipts(run_id);
        CREATE INDEX IF NOT EXISTS idx_token_saver_context_slot_receipts_provisional
            ON token_saver_context_slot_receipts(lifecycle)
            WHERE lifecycle = 'provisional';
        CREATE TABLE IF NOT EXISTS token_saver_context_slot_arm_receipts (
            run_id TEXT NOT NULL,
            destination_provider_thread_id TEXT NOT NULL,
            snapshot_digest TEXT NOT NULL,
            source_message_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            format TEXT NOT NULL CHECK(format IN ('human', 'rcw1', 'rcs1')),
            source_bound INTEGER NOT NULL CHECK(source_bound IN (0, 1)),
            producer_id TEXT NOT NULL,
            producer_revision TEXT NOT NULL,
            abi_revision TEXT NOT NULL,
            generation TEXT NOT NULL CHECK(generation IN ('passed', 'failed', 'unknown', 'not_required')),
            structural TEXT NOT NULL CHECK(structural IN ('passed', 'failed', 'unknown', 'not_required')),
            semantic TEXT NOT NULL CHECK(semantic IN ('passed', 'failed', 'unknown', 'not_required')),
            recovery TEXT NOT NULL CHECK(recovery IN ('passed', 'failed', 'unknown', 'not_required')),
            projection TEXT NOT NULL CHECK(projection IN ('projected', 'not_projected', 'unknown')),
            availability TEXT NOT NULL CHECK(availability IN ('available', 'unavailable', 'unknown')),
            eligible INTEGER NOT NULL CHECK(eligible IN (0, 1)),
            proven_effective_count INTEGER
                CHECK(proven_effective_count IS NULL OR proven_effective_count >= 0),
            PRIMARY KEY(
                run_id,
                destination_provider_thread_id,
                snapshot_digest,
                source_message_id,
                ordinal,
                format
            ),
            FOREIGN KEY(
                run_id,
                destination_provider_thread_id,
                snapshot_digest,
                source_message_id,
                ordinal
            ) REFERENCES token_saver_context_slot_receipts(
                run_id,
                destination_provider_thread_id,
                snapshot_digest,
                source_message_id,
                ordinal
            ) ON DELETE CASCADE
        );
        """),
        // Last compiled Brain payload per model-call attempt. Source/Effective
        // preview reads the same JSON the send path persisted. Numbered 75
        // because production already shipped Token Saver receipts as 72-74.
        SchemaStep(75, """
        CREATE TABLE IF NOT EXISTS bot_context_receipts (
            id TEXT PRIMARY KEY NOT NULL,
            bot_id TEXT NOT NULL,
            conversation_id TEXT,
            run_id TEXT,
            revision_id TEXT NOT NULL,
            payload_digest TEXT NOT NULL,
            receipt_json TEXT NOT NULL,
            assembled_at TEXT NOT NULL,
            FOREIGN KEY(bot_id) REFERENCES bots(id)
        );
        CREATE INDEX IF NOT EXISTS idx_bot_context_receipts_bot
            ON bot_context_receipts(bot_id, assembled_at DESC);
        CREATE INDEX IF NOT EXISTS idx_bot_context_receipts_conversation
            ON bot_context_receipts(conversation_id, assembled_at DESC);
        """),
        SchemaStep(76, """
        ALTER TABLE bot_routine_definitions ADD COLUMN schedule_spec_json TEXT NOT NULL DEFAULT '';
        """),
        SchemaStep(77, """
        ALTER TABLE agent_runs ADD COLUMN terminal_reason TEXT;
        """),
        SchemaStep(78, """
        ALTER TABLE token_saver_savings ADD COLUMN idempotency_key TEXT NOT NULL DEFAULT '';
        CREATE UNIQUE INDEX IF NOT EXISTS idx_token_saver_savings_idempotency
            ON token_saver_savings(idempotency_key)
            WHERE idempotency_key != '';
        """),
        SchemaStep(79, """
        CREATE TABLE IF NOT EXISTS agent_item_host_attestations (
            run_id TEXT NOT NULL,
            seq INTEGER NOT NULL,
            stream_event_id INTEGER NOT NULL,
            event_kind TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY(run_id, seq),
            FOREIGN KEY(run_id) REFERENCES agent_runs(id) ON DELETE CASCADE
        );
        INSERT OR IGNORE INTO agent_item_host_attestations(
            run_id, seq, stream_event_id, event_kind, payload_json, created_at
        )
        SELECT run_id, seq, id, event_kind, payload_json, created_at
        FROM agent_stream_events
        WHERE event_kind LIKE 'itemHostMetadata(% distill=true)';
        CREATE VIEW IF NOT EXISTS agent_replay_stream_events AS
        SELECT e.id AS id, e.payload_json, r.started_at, e.seq,
               e.id AS ordering_id, e.run_id, r.thread_id
        FROM agent_stream_events e
        JOIN agent_runs r ON r.id = e.run_id
        WHERE NOT EXISTS (
            SELECT 1 FROM agent_item_host_attestations h
            WHERE h.run_id = e.run_id AND h.seq = e.seq
        )
        UNION ALL
        SELECT -h.rowid AS id, h.payload_json, r.started_at, h.seq,
               h.stream_event_id AS ordering_id, h.run_id, r.thread_id
        FROM agent_item_host_attestations h
        JOIN agent_runs r ON r.id = h.run_id;
        """),
        SchemaStep(80, """
        CREATE TABLE IF NOT EXISTS bot_queued_follow_ups (
            id TEXT PRIMARY KEY,
            bot_id TEXT NOT NULL,
            conversation_id TEXT,
            text TEXT NOT NULL,
            payload_json TEXT NOT NULL DEFAULT '{}',
            sort_order INTEGER NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS bot_queued_follow_ups_bot_sort
            ON bot_queued_follow_ups(bot_id, sort_order);
        """),
        SchemaStep(81, """
        CREATE INDEX IF NOT EXISTS idx_agent_threads_running
            ON agent_threads(id)
            WHERE status = 'running';
        """),
        SchemaStep(82, """
        CREATE INDEX IF NOT EXISTS idx_audit_log_action_id
            ON audit_log(action, id);
        """),
        SchemaStep(83, """
        CREATE INDEX IF NOT EXISTS idx_agent_threads_workspace_updated
            ON agent_threads(workspace_id, updated_at DESC, id DESC);
        """),
        SchemaStep(84, """
        ALTER TABLE agent_threads ADD COLUMN reasoning_model TEXT;
        """),
        SchemaStep(scheduledTaskModelColumnsSchemaVersion, scheduledTaskModelColumnsMigrationSQL),
        SchemaStep(threadActorSchemaVersion, """
        ALTER TABLE agent_threads ADD COLUMN actor_json TEXT;
        ALTER TABLE agent_threads ADD COLUMN actor_locked_at TEXT;
        ALTER TABLE agent_threads ADD COLUMN execution_target TEXT;
        """),
        SchemaStep(threadGuestRuntimeSchemaVersion, """
        ALTER TABLE agent_threads ADD COLUMN guest_runtime TEXT;
        """),
        SchemaStep(botTeamsGroupsSchemaVersion, botTeamsGroupsMigrationSQL),
        SchemaStep(botConversationRoutingSchemaVersion, botConversationRoutingMigrationSQL),
        SchemaStep(threadForkColumnsSchemaVersion, """
        ALTER TABLE agent_threads ADD COLUMN parent_thread_id TEXT;
        ALTER TABLE agent_threads ADD COLUMN is_ephemeral INTEGER NOT NULL DEFAULT 0;
        """),
        SchemaStep(agentRunResultsSchemaVersion, """
        CREATE TABLE IF NOT EXISTS agent_run_results (
            run_id TEXT PRIMARY KEY REFERENCES agent_runs(id) ON DELETE CASCADE,
            final_message_id TEXT,
            summary TEXT,
            viewed_at TEXT,
            attention_acknowledged_at TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_agent_run_results_viewed
            ON agent_run_results(viewed_at, run_id);
        INSERT OR IGNORE INTO agent_run_results(run_id)
            SELECT id FROM agent_runs
            WHERE status IN ('completed', 'failed', 'cancelled', 'interrupted');
        CREATE TABLE IF NOT EXISTS activity_notification_state (
            item_id TEXT PRIMARY KEY,
            viewed_at TEXT,
            acknowledged_at TEXT
        );
        """),
        SchemaStep(botReplyStyleSchemaVersion, """
        ALTER TABLE bots ADD COLUMN reply_verbosity TEXT NOT NULL DEFAULT 'human';
        ALTER TABLE bots ADD COLUMN caveman_enabled INTEGER NOT NULL DEFAULT 1;
        UPDATE bots SET caveman_enabled = 0 WHERE lower(handle) = 'titio';
        """),
        SchemaStep(titioNoticesSchemaVersion, titioNoticesMigrationSQL),
        SchemaStep(botContextsSchemaVersion, """
        CREATE TABLE IF NOT EXISTS bot_context_bindings (
            host_id TEXT NOT NULL CHECK(length(trim(host_id)) > 0),
            bot_id TEXT NOT NULL,
            context_key TEXT NOT NULL,
            contract_version INTEGER NOT NULL CHECK(typeof(contract_version) = 'integer'),
            state TEXT NOT NULL CHECK(state IN ('active', 'revoked')),
            policy_revision INTEGER NOT NULL CHECK(typeof(policy_revision) = 'integer' AND policy_revision > 0),
            actions TEXT NOT NULL,
            PRIMARY KEY(host_id, bot_id, context_key),
            FOREIGN KEY(bot_id) REFERENCES bots(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_bot_context_bindings_bot ON bot_context_bindings(bot_id, host_id);
        """),
        SchemaStep(botConversationContextsSchemaVersion, """
        CREATE TABLE IF NOT EXISTS bot_conversation_contexts (
            conversation_id TEXT PRIMARY KEY NOT NULL,
            host_id TEXT NOT NULL CHECK(length(trim(host_id)) > 0),
            bot_id TEXT NOT NULL,
            context_key TEXT NOT NULL,
            policy_revision INTEGER NOT NULL CHECK(typeof(policy_revision) = 'integer' AND policy_revision > 0),
            context_version INTEGER NOT NULL CHECK(typeof(context_version) = 'integer'),
            thread_id TEXT NOT NULL COLLATE NOCASE UNIQUE,
            FOREIGN KEY(conversation_id) REFERENCES bot_conversations(id) ON DELETE CASCADE
        );
        CREATE TRIGGER IF NOT EXISTS bot_conversation_contexts_immutable
        BEFORE UPDATE ON bot_conversation_contexts
        BEGIN SELECT RAISE(ABORT, 'bot conversation context is immutable'); END;
        CREATE TRIGGER IF NOT EXISTS bot_conversation_contexts_link_guard
        BEFORE INSERT ON bot_conversation_contexts
        WHEN NOT EXISTS (
            SELECT 1 FROM bot_conversations
            WHERE id = NEW.conversation_id
              AND bot_id = NEW.bot_id
              AND linked_agent_thread_id = NEW.thread_id COLLATE NOCASE
        )
        BEGIN SELECT RAISE(ABORT, 'conversation context thread mismatch'); END;
        CREATE TRIGGER IF NOT EXISTS bot_conversation_pinned_thread_immutable
        BEFORE UPDATE OF linked_agent_thread_id ON bot_conversations
        WHEN EXISTS (
            SELECT 1 FROM bot_conversation_contexts
            WHERE conversation_id = OLD.id
              AND OLD.linked_agent_thread_id IS NOT NEW.linked_agent_thread_id
        )
        BEGIN SELECT RAISE(ABORT, 'pinned conversation thread is immutable'); END;
        CREATE TRIGGER IF NOT EXISTS bot_conversation_pinned_thread_insert_guard
        BEFORE INSERT ON bot_conversations
        WHEN NEW.linked_agent_thread_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM bot_conversation_contexts
            WHERE thread_id = NEW.linked_agent_thread_id COLLATE NOCASE
              AND conversation_id <> NEW.id
        )
        BEGIN SELECT RAISE(ABORT, 'thread already has a contextual conversation'); END;
        CREATE TRIGGER IF NOT EXISTS bot_conversation_pinned_thread_update_guard
        BEFORE UPDATE OF linked_agent_thread_id ON bot_conversations
        WHEN NEW.linked_agent_thread_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM bot_conversation_contexts
            WHERE thread_id = NEW.linked_agent_thread_id COLLATE NOCASE
              AND conversation_id <> OLD.id
        )
        BEGIN SELECT RAISE(ABORT, 'thread already has a contextual conversation'); END;
        """),
        SchemaStep(botContextDelegationsSchemaVersion, """
        CREATE TABLE IF NOT EXISTS bot_context_delegations (
            child_run_id TEXT PRIMARY KEY NOT NULL COLLATE NOCASE,
            parent_run_id TEXT NOT NULL COLLATE NOCASE,
            payload_json TEXT NOT NULL CHECK(length(payload_json) <= 16384),
            closed INTEGER NOT NULL DEFAULT 0 CHECK(typeof(closed) = 'integer' AND closed IN (0, 1))
        );
        CREATE INDEX IF NOT EXISTS idx_bot_context_delegations_parent_run
            ON bot_context_delegations(parent_run_id);
        CREATE TRIGGER IF NOT EXISTS bot_context_delegations_insert_guard
        BEFORE INSERT ON bot_context_delegations
        WHEN EXISTS (SELECT 1 FROM bot_context_delegations WHERE child_run_id = NEW.child_run_id)
        BEGIN SELECT RAISE(ABORT, 'bot context delegation already exists'); END;
        CREATE TRIGGER IF NOT EXISTS bot_context_delegations_update_guard
        BEFORE UPDATE ON bot_context_delegations
        WHEN NEW.child_run_id COLLATE BINARY IS NOT OLD.child_run_id COLLATE BINARY
          OR NEW.parent_run_id COLLATE BINARY IS NOT OLD.parent_run_id COLLATE BINARY
          OR NEW.payload_json IS NOT OLD.payload_json
          OR NEW.closed < OLD.closed
        BEGIN SELECT RAISE(ABORT, 'bot context delegation is immutable'); END;
        CREATE TRIGGER IF NOT EXISTS bot_context_delegations_delete_guard
        BEFORE DELETE ON bot_context_delegations
        BEGIN SELECT RAISE(ABORT, 'bot context delegation cannot be deleted'); END;
        """),
        SchemaStep(hostRestoreQueueHoldsSchemaVersion, """
        CREATE TABLE IF NOT EXISTS host_restore_queue_holds (
            kind TEXT NOT NULL CHECK(kind IN ('agent','bot')),
            queue_id TEXT NOT NULL COLLATE NOCASE,
            approved INTEGER NOT NULL DEFAULT 0 CHECK(approved IN (0,1)),
            attempt_run_id TEXT,
            PRIMARY KEY(kind, queue_id)
        );
        """),
        SchemaStep(relayKeysSchemaVersion, """
        ALTER TABLE device_trust ADD COLUMN relay_public_key BLOB;
        """),
        SchemaStep(botSortOrderSchemaVersion, """
        ALTER TABLE bots ADD COLUMN sort_order INTEGER;
        """),
        SchemaStep(scheduledTaskRunOptionsSchemaVersion, """
        ALTER TABLE scheduled_tasks ADD COLUMN distill_ultracode INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE scheduled_tasks ADD COLUMN permission_mode TEXT NOT NULL DEFAULT 'full_access';
        ALTER TABLE scheduled_tasks ADD COLUMN interaction_mode TEXT NOT NULL DEFAULT 'default';
        ALTER TABLE scheduled_tasks ADD COLUMN execution_mode TEXT NOT NULL DEFAULT 'local';
        ALTER TABLE scheduled_tasks ADD COLUMN base_branch TEXT;
        """),
        SchemaStep(virtualMachinesSchemaVersion, """
        CREATE TABLE virtual_machines (
            id TEXT PRIMARY KEY NOT NULL COLLATE NOCASE,
            name TEXT NOT NULL,
            workspace_id TEXT COLLATE NOCASE,
            created_at REAL NOT NULL
        );
        ALTER TABLE bots ADD COLUMN execution_destination TEXT;
        ALTER TABLE agent_threads ADD COLUMN execution_destination TEXT;
        UPDATE agent_threads SET execution_destination='own_vm'
            WHERE execution_target='vm' AND guest_runtime='guest-v1';
        """),
        SchemaStep(titioObservationSchemaVersion, """
        CREATE TABLE titio_observations (
            seq INTEGER PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            occurred_at REAL NOT NULL,
            processed_at REAL
        );
        CREATE INDEX idx_titio_observations_pending ON titio_observations(processed_at, seq);
        """),
        SchemaStep(scheduledTaskConcurrencySchemaVersion, """
        ALTER TABLE scheduled_tasks ADD COLUMN max_concurrent_runs INTEGER NOT NULL DEFAULT 1;
        """),
    ]

    /// Additive and idempotent. `key` reuses today's banner identifiers, so a
    /// replayed or second producer upserts the same row instead of posting twice.
    static let titioNoticesMigrationSQL: String = """
        CREATE TABLE IF NOT EXISTS titio_notices (
            key TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            urgency TEXT NOT NULL,
            source_json TEXT NOT NULL,
            facts_json TEXT NOT NULL,
            actions_json TEXT,
            state TEXT NOT NULL,
            resolution TEXT,
            message_id TEXT,
            batch_id TEXT,
            occurred_at REAL NOT NULL,
            posted_at REAL,
            banner_at REAL,
            resolved_at REAL
        );
        CREATE INDEX IF NOT EXISTS idx_titio_notices_state ON titio_notices(state, occurred_at);
        CREATE INDEX IF NOT EXISTS idx_titio_notices_message ON titio_notices(message_id);
        CREATE INDEX IF NOT EXISTS idx_titio_notices_posted ON titio_notices(posted_at);
        CREATE TABLE IF NOT EXISTS titio_inbox_state (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            conversation_id TEXT,
            unread_count INTEGER NOT NULL DEFAULT 0,
            last_preview TEXT,
            last_at REAL,
            armed_reply_key TEXT,
            armed_at REAL
        );
        """

    /// Fork/side columns are added only when missing so a database that already
    /// recorded v90 (or a partial prior run) does not fail the ALTER.
    private static func addMissingThreadForkColumns(_ db: SQLiteDB) throws {
        let existingColumns: Set<String> = try {
            let statement = try db.prepare("PRAGMA table_info(agent_threads);")
            defer { statement.reset() }
            var names = Set<String>()
            while try statement.step() {
                if let name = statement.columnText(1) { names.insert(name) }
            }
            return names
        }()
        if !existingColumns.contains("parent_thread_id") {
            try db.execute("ALTER TABLE agent_threads ADD COLUMN parent_thread_id TEXT;")
        }
        if !existingColumns.contains("is_ephemeral") {
            try db.execute("ALTER TABLE agent_threads ADD COLUMN is_ephemeral INTEGER NOT NULL DEFAULT 0;")
        }
    }

    /// Additive and idempotent. One row per desk conversation holds the
    /// encoded Bot desk route (Main/Worker model, efforts, permission, run-as
    /// user) that the Mac desk and paired `bot.send` both use. Rows go away
    /// with their conversation.
    static let botConversationRoutingMigrationSQL: String = """
        CREATE TABLE IF NOT EXISTS bot_conversation_routing (
            conversation_id TEXT PRIMARY KEY NOT NULL
                REFERENCES bot_conversations(id) ON DELETE CASCADE,
            routing_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        """

    /// Additive and idempotent: every object uses IF NOT EXISTS, and the
    /// bot_conversations.group_id column is added by `addMissingBotConversationGroupColumn`
    /// before this SQL runs, so a database that already has it (e.g. from a
    /// sibling branch) migrates cleanly.
    static let botTeamsGroupsMigrationSQL: String = """
        CREATE TABLE IF NOT EXISTS bot_teams (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            avatar_symbol TEXT NOT NULL DEFAULT 'person.3.fill',
            sort_order INTEGER NOT NULL DEFAULT 0,
            revision INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_bot_teams_sort
            ON bot_teams(sort_order, created_at);

        CREATE TABLE IF NOT EXISTS bot_team_members (
            team_id TEXT NOT NULL,
            bot_id TEXT NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            added_at TEXT NOT NULL,
            PRIMARY KEY(team_id, bot_id),
            FOREIGN KEY(team_id) REFERENCES bot_teams(id) ON DELETE CASCADE,
            FOREIGN KEY(bot_id) REFERENCES bots(id)
        );
        CREATE INDEX IF NOT EXISTS idx_bot_team_members_bot
            ON bot_team_members(bot_id);

        CREATE TABLE IF NOT EXISTS bot_group_conversations (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            team_id TEXT,
            room_thread_id TEXT NOT NULL UNIQUE,
            policy TEXT NOT NULL DEFAULT 'roundtable'
                CHECK(policy IN ('roundtable', 'lead', 'mentions_only')),
            lead_bot_id TEXT,
            max_auto_hops INTEGER NOT NULL DEFAULT 4
                CHECK(max_auto_hops BETWEEN 0 AND 8),
            pinned INTEGER NOT NULL DEFAULT 0,
            hidden INTEGER NOT NULL DEFAULT 0,
            unread INTEGER NOT NULL DEFAULT 0,
            attention_state TEXT NOT NULL DEFAULT 'none',
            revision INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(team_id) REFERENCES bot_teams(id) ON DELETE SET NULL
        );
        CREATE INDEX IF NOT EXISTS idx_bot_group_conversations_updated
            ON bot_group_conversations(pinned DESC, updated_at DESC);

        CREATE TABLE IF NOT EXISTS bot_group_participants (
            group_id TEXT NOT NULL,
            bot_id TEXT NOT NULL,
            member_conversation_id TEXT NOT NULL UNIQUE,
            sort_order INTEGER NOT NULL DEFAULT 0,
            joined_at TEXT NOT NULL,
            left_at TEXT,
            seen_room_message_id TEXT,
            seen_room_created_at TEXT,
            PRIMARY KEY(group_id, bot_id),
            FOREIGN KEY(group_id) REFERENCES bot_group_conversations(id) ON DELETE CASCADE,
            FOREIGN KEY(bot_id) REFERENCES bots(id)
        );
        CREATE INDEX IF NOT EXISTS idx_bot_group_participants_bot
            ON bot_group_participants(bot_id);

        CREATE TABLE IF NOT EXISTS bot_group_turns (
            id TEXT PRIMARY KEY NOT NULL,
            group_id TEXT NOT NULL,
            round_id TEXT NOT NULL,
            trigger_message_id TEXT,
            bot_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            hop INTEGER NOT NULL DEFAULT 0,
            state TEXT NOT NULL DEFAULT 'planned'
                CHECK(state IN ('planned', 'waiting_for_bot', 'running', 'completed',
                                'failed', 'cancelled', 'interrupted', 'skipped')),
            room_message_id TEXT NOT NULL UNIQUE,
            member_run_id TEXT,
            submit_key TEXT,
            error TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(group_id) REFERENCES bot_group_conversations(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_bot_group_turns_group_state
            ON bot_group_turns(group_id, state, ordinal);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_bot_group_turns_round_bot_hop
            ON bot_group_turns(round_id, bot_id, hop);
        CREATE INDEX IF NOT EXISTS idx_bot_group_turns_bot_state
            ON bot_group_turns(bot_id, state);
        -- bot.group.send is idempotent by submit_key: a retried send cannot
        -- insert a second round for the same bots.
        CREATE UNIQUE INDEX IF NOT EXISTS idx_bot_group_turns_submit
            ON bot_group_turns(group_id, submit_key, bot_id, hop)
            WHERE submit_key IS NOT NULL;

        CREATE INDEX IF NOT EXISTS idx_bot_conversations_group
            ON bot_conversations(group_id)
            WHERE group_id IS NOT NULL;
        """

    private static func addMissingBotConversationGroupColumn(_ db: SQLiteDB) throws {
        let statement = try db.prepare("PRAGMA table_info(bot_conversations);")
        var hasGroupID = false
        while try statement.step() {
            if statement.columnText(1) == "group_id" { hasGroupID = true }
        }
        statement.reset()
        if !hasGroupID {
            try db.execute("ALTER TABLE bot_conversations ADD COLUMN group_id TEXT;")
        }
    }

    /// Tables that exist in the schema for historical reasons but have no
    /// active repository or call sites in the current codebase.  They are
    /// retained to avoid a destructive migration step; they are candidates for
    /// removal once a future migration cycle confirms they are safe to drop.
    ///
    /// - workspace_selection: seeded by Bootstrap only; no queries elsewhere.
    /// - terminal_sessions: superseded by terminal_output_chunks (step 7).
    /// - browser_profiles: browser-profile feature was never implemented.
    public static func knownDeadTableNames() -> Set<String> {
        ["workspace_selection", "terminal_sessions", "browser_profiles"]
    }

    // PERF: ISO8601DateFormatter is expensive; reuse one for migration timestamps.
    private static let migrationAppliedAtLock = NSLock()
    private static let migrationAppliedAtFormatter = ISO8601DateFormatter()

    static func trustedRestoreSchema(version: Int) throws -> SQLiteDB {
        guard [93, 96, hostRestoreQueueHoldsSchemaVersion, relayKeysSchemaVersion, botSortOrderSchemaVersion, scheduledTaskRunOptionsSchemaVersion, virtualMachinesSchemaVersion, currentVersion].contains(version) else {
            throw SQLiteError.execute("unsupported restore schema version")
        }
        let db = try SQLiteDB(path: ":memory:")
        try migrateSteps(db, steps.filter { $0.version <= version })
        try healBotTeamsGroupsSchema(db)
        try db.execute(botConversationRoutingMigrationSQL)
        return db
    }

    public static func migrate(_ db: SQLiteDB) throws {
        try migrateSteps(db, steps)
        try healBotTeamsGroupsSchema(db)
        // Same sibling-branch hazard as teams/groups: a branch that recorded
        // v89+ first would skip the step. The DDL is idempotent.
        try db.execute(botConversationRoutingMigrationSQL)
    }

    /// `migrateSteps` skips by version, not by step. If a sibling branch
    /// recorded its own step at v88 or later first, the teams/groups step never
    /// ran. Its objects are additive and idempotent, so re-apply them whenever
    /// any is missing.
    static func healBotTeamsGroupsSchema(_ db: SQLiteDB) throws {
        let probe = try db.prepare("""
            SELECT COUNT(*) FROM sqlite_master
            WHERE name IN ('bot_teams', 'bot_team_members', 'bot_group_conversations',
                           'bot_group_participants', 'bot_group_turns', 'idx_bot_group_turns_submit');
            """)
        let objects = try probe.step() ? probe.columnInt64(0) : 0
        probe.reset()
        let columns = try db.prepare("PRAGMA table_info(bot_conversations);")
        var hasGroupID = false
        while try columns.step() {
            if columns.columnText(1) == "group_id" { hasGroupID = true }
        }
        columns.reset()
        guard objects < 6 || !hasGroupID else { return }
        try db.transaction {
            try addMissingBotConversationGroupColumn(db)
            try db.execute(botTeamsGroupsMigrationSQL)
        }
    }

    private static func addMissingScheduledTaskModelColumns(_ db: SQLiteDB) throws {
        let existingColumns: Set<String> = try {
            let statement = try db.prepare("PRAGMA table_info(scheduled_tasks);")
            defer { statement.reset() }
            var names = Set<String>()
            while try statement.step() {
                if let name = statement.columnText(1) { names.insert(name) }
            }
            return names
        }()

        for column in scheduledTaskModelColumns where !existingColumns.contains(column.name) {
            try db.execute("ALTER TABLE scheduled_tasks ADD COLUMN \(column.name) \(column.type);")
        }
    }

    /// Applies the given steps transactionally and idempotently.
    /// Each pending step (SQL + its `schema_meta` row) is wrapped in a single
    /// `BEGIN IMMEDIATE ... COMMIT`, rolling back on any error so a step is
    /// all-or-nothing: a step that throws mid-way leaves both the schema and
    /// `schema_meta` unchanged. Already-applied steps (version <= current MAX)
    /// are skipped, so re-running is a no-op.
    static func migrateSteps(_ db: SQLiteDB, _ steps: [SchemaStep]) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS schema_meta (
                version INTEGER PRIMARY KEY,
                applied_at TEXT NOT NULL
            );
        """)
        let stmt = try db.prepare("SELECT MAX(version) FROM schema_meta;")
        defer { stmt.reset() }
        var current: Int = 0
        if try stmt.step() {
            if !stmt.columnIsNull(0) {
                current = Int(stmt.columnInt64(0))
            }
        }
        // Finalize the schema-version read before a pending migration rebuilds
        // or drops a table. An active sqlite statement holds a schema read lock.
        stmt.reset()
        let pending = steps.filter { $0.version > current }
        for step in pending.sorted(by: { $0.version < $1.version }) {
            try db.transaction {
                // Some earlier v84 builds already installed these columns.
                if step.version == Self.scheduledTaskModelColumnsSchemaVersion {
                    try Self.addMissingScheduledTaskModelColumns(db)
                } else if step.version == Self.botTeamsGroupsSchemaVersion {
                    try Self.addMissingBotConversationGroupColumn(db)
                    try db.execute(step.sql)
                } else if step.version == Self.threadForkColumnsSchemaVersion {
                    try Self.addMissingThreadForkColumns(db)
                } else {
                    try db.execute(step.sql)
                }
                let ins = try db.prepare("INSERT OR IGNORE INTO schema_meta(version, applied_at) VALUES(?, ?);")
                try ins.bind(1, Int64(step.version))
                Self.migrationAppliedAtLock.lock()
                let appliedAt = Self.migrationAppliedAtFormatter.string(from: Date())
                Self.migrationAppliedAtLock.unlock()
                try ins.bind(2, appliedAt)
                _ = try ins.step()
            }
        }
    }
}
