import metrics, tables

declarePublicGauge query_time_secs,
  "query time measured in nanoseconds", labels = ["query", "phase"]

declarePublicCounter query_count,
  "number of times a query is being performed", labels = ["query"]

## Maps parts of the possible known queries with a fixed and shorter query label.
const QueriesToMetricMap* = toTable(
  {
    "contentTopic IN": "content_topic",
    "SELECT version()": "select_version",
    "WITH min_timestamp": "messages_lookup",
    "SELECT messageHash FROM messages WHERE pubsubTopic = ? AND timestamp >= ? AND timestamp <= ? ORDER BY timestamp DESC, messageHash DESC LIMIT ?":
      "msg_hash_no_ctopic",
    "AS partition_name": "get_partitions_list",
    "SELECT COUNT(1) FROM messages": "count_msgs",
    "SELECT messageHash FROM messages WHERE (timestamp, messageHash) < (?,?) AND pubsubTopic = ? AND timestamp >= ? AND timestamp <= ? ORDER BY timestamp DESC, messageHash DESC LIMIT ?":
      "msg_hash_with_cursor",
    "SELECT pg_database_size(current_database())": "get_database_size",
    "DELETE FROM messages_lookup WHERE timestamp": "delete_from_msgs_lookup",
    "DROP TABLE messages_": "drop_partition_table",
    "ALTER TABLE messages DETACH PARTITION": "detach_partition",
    "SELECT pg_size_pretty(pg_total_relation_size(C.oid))": "get_partition_size",
    "pg_try_advisory_lock": "try_advisory_lock",
    "SELECT messageHash FROM messages ORDER BY timestamp DESC, messageHash DESC LIMIT ?":
      "get_all_msg_hash",
    "SELECT pg_advisory_unlock": "advisory_unlock",
    "ANALYZE messages": "analyze_messages",
    "SELECT EXISTS": "check_version_table_exists",
  }
)
