# Entity-Relationship Diagram (ERD)

This diagram describes the database schema used by the `audit-mcp` service and shared across the Claude Orchestrator project.

```mermaid
erDiagram
    SESSIONS ||--o{ BATCHES : "has"
    SESSIONS ||--o{ TASKS : "has"
    BATCHES ||--o{ TASKS : "contains"
    TASKS ||--o{ TASKS : "parent/child"
    TASKS ||--o{ TASK_TAGS : "tagged with"
    TAGS ||--o{ TASK_TAGS : "defines"

    SESSIONS {
        text id PK
        integer started_at
        integer ended_at
        text claude_model
        text notes
    }

    BATCHES {
        text id PK
        text session_id FK
        integer started_at
        integer ended_at
        integer task_count
        integer failed_count
        integer total_tokens
    }

    TASKS {
        integer id PK
        text invocation_id UNIQUE
        text batch_id FK
        text session_id FK
        integer parent_task_id FK
        integer task_index
        text tool_type
        text project
        text cwd
        text prompt_slug
        text prompt_hash
        text prompt
        text url
        text sandbox
        text approval
        text model
        integer skip_git_check
        integer started_at
        integer ended_at
        integer duration_ms
        integer exit_code
        text status
        text failure_reason
        integer timed_out
        integer output_capped
        integer stdout_bytes
        integer stderr_bytes
        text output_truncated
        text output_full
        text error_text
        integer redaction_count
        integer token_est
        real cost_est_usd
    }

    TASK_TAGS {
        integer task_id PK, FK
        text tag PK, FK
        text tag_source
    }

    TAGS {
        text name PK
        text description
        text color
    }

    CONFIG {
        text key PK
        text value
        text updated_at
    }

    SECURITY_EVENTS {
        integer id PK
        text session_id
        integer timestamp_ms
        text level
        text hook
        text tool
        text action
        text severity
        text pattern_matched
        text command_preview
        text cwd
    }

    WEB_TASKS {
        integer id PK
        text session_id
        text invocation_key
        text tool_name
        text prompt
        text prompt_hash
        text status
        integer started_at
        integer ended_at
        integer duration_ms
        text error_text
        text cwd
    }
```

## Relationships

- **Sessions & Batches**: A session can contain multiple batches (1:N).
- **Sessions & Tasks**: A session can have multiple tasks directly associated with it (1:N).
- **Batches & Tasks**: A batch groups multiple tasks (1:N).
- **Tasks & Tasks**: A task can have a parent task, supporting nested task execution (Self-referencing 1:N).
- **Tasks & Tags**: Tasks are linked to tags through the `task_tags` join table (M:N).
- **Security Events**: Log security-related occurrences, typically within a session.
- **Web Tasks**: Specialized tasks specifically for web-related tool invocations.
- **Config**: Global key-value settings for the orchestrator.
