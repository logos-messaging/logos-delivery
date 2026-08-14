const ContentScriptVersion_8* = """

-- Recreate messages_lookup as a partitioned table (issue #3790): retention now
-- drops hourly lookup partitions in lockstep with the messages partitions,
-- instead of bulk-DELETEs whose dead index space was never reclaimed.
-- Rows are rebuilt from the messages partitions by the partition factory's
-- reconcile pass (ensureLookupPartitions, every iteration). The redundant idx_messages_lookup_messagehash is not
-- recreated: the primary key already covers messagehash as leading column.
-- idx_messages_lookup_timestamp is likewise gone: retention no longer deletes
-- by timestamp, and partition pruning plus the per-partition PK cover reads.
DROP TABLE IF EXISTS messages_lookup;

CREATE TABLE messages_lookup (
   timestamp BIGINT NOT NULL,
   messageHash VARCHAR NOT NULL,
   CONSTRAINT messageIndexLookupTable PRIMARY KEY (messageHash, timestamp)
  ) PARTITION BY RANGE (timestamp);

-- Update to new version
UPDATE version SET version = 8 WHERE version = 7;

"""
