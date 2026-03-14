# Graphical Entity-Relationship Diagram

This diagram describes the database schema used by the `audit-mcp` service and shared across the Claude Orchestrator project.

                          ╔══════════════════════╗
                          ║       SESSIONS       ║
                          ╠══════════════════════╣
                          ║ id (PK)              ║
                          ║ started_at           ║
                          ║ ended_at             ║
                          ║ claude_model         ║
                          ║ notes                ║
                          ╚═══════════╤══════════╝
                                      │
            ┌─────────────────────────┼─────────────────────────┬─────────────────────────┐
            │                         │                         │                         │
╔═══════════╧══════════╗  ╔═══════════╧══════════╗  ╔═══════════╧══════════╗  ╔═══════════╧══════════╗
║       BATCHES        ║  ║        TASKS         ║  ║   SECURITY_EVENTS    ║  ║      WEB_TASKS       ║
╠══════════════════════╣  ╠══════════════════════╣  ╠══════════════════════╣  ╠══════════════════════╣
║ id (PK)              ║  ║ id (PK)              ║  ║ id (PK)              ║  ║ id (PK)              ║
║ session_id (FK)      ║  ║ invocation_id        ║  ║ session_id           ║  ║ session_id           ║
║ started_at           ║  ║ batch_id (FK)        ║  ║ timestamp_ms         ║  ║ invocation_key       ║
║ ended_at             ║  ║ session_id (FK)      ║  ║ level                ║  ║ tool_name            ║
║ task_count           ║  ║ parent_task_id (FK)  ║  ║ hook                 ║  ║ status               ║
║ failed_count         ║  ║ tool_type            ║  ║ action               ║  ║ started_at           ║
║ total_tokens         ║  ║ project              ║  ║ severity             ║  ║ ended_at             ║
╚══════════════════════╝  ║ cwd                  ║  ║ pattern_matched      ║  ║ duration_ms          ║
                          ║ status               ║  ║ command_preview      ║  ║ error_text           ║
                          ║ token_est            ║  ║ cwd                  ║  ║ cwd                  ║
                          ║ cost_est_usd         ║  ╚══════════════════════╝  ╚══════════════════════╝
                          ╚═══════════╤══════════╝
                                      │
                          ╔═══════════╧══════════╗
                          ║       TASK_TAGS      ║
                          ╠══════════════════════╣
                          ║ task_id (FK)         ║
                          ║ tag (FK)             ║
                          ║ tag_source           ║
                          ╚═══════════╤══════════╝
                                      │
                                      ▼
                          ╔═══════════╧══════════╗     ╔══════════════════════╗
                          ║         TAGS         ║     ║        CONFIG        ║
                          ╠══════════════════════╣     ╠══════════════════════╣
                          ║ name (PK)            ║     ║ key (PK)             ║
                          ║ description          ║     ║ value                ║
                          ║ color                ║     ║ updated_at           ║
                          ╚══════════════════════╝     ╚══════════════════════╝

## Relationships

- **Sessions (Top-Level)**: Central anchor. Batches, Tasks, Security Events, and Web Tasks all link back to a Session.
- **Sessions & Batches**: One session contains many batches (1:N).
- **Sessions & Tasks**: One session has many tasks directly (1:N).
- **Batches & Tasks**: One batch groups many tasks (1:N).
- **Task Hierarchy**: Tasks support a self-referencing `parent_task_id` for nested execution (1:N self-ref).
- **Tagging**: Tasks are linked to Tags via the `TASK_TAGS` join table (M:N).
- **Security Events**: Log security-related hook events within a session.
- **Web Tasks**: Specialized records for web-tool invocations within a session.
- **Config**: Global key-value settings; no FK relationships.
