Clean up the delegation audit logs.

1. Read the summary index at `~/.claude/logs/delegations.jsonl`
2. List all detail files in `~/.claude/logs/details/`
3. Identify **orphaned** detail files — files in `details/` that are NOT referenced by any `detail` field in the summary index
4. Identify **expired** detail files — files older than 30 days (by modification time)
5. Report what was found:
   - Total summary entries
   - Total detail files
   - Orphaned detail files (with names)
   - Expired detail files (with names and age)
   - Disk usage of the details directory
6. Delete orphaned and expired files
7. Remove any summary entries whose `detail` file no longer exists
8. Report final state after cleanup
