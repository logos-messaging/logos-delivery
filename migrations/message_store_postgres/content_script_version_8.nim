const ContentScriptVersion_8* = """

-- Recreate messages_lookup as a partitioned table (issue #3790): retention now
-- drops hourly lookup partitions in lockstep with the messages partitions,
-- instead of bulk-DELETEs whose dead index space was never reclaimed.
-- Rows are rebuilt from the messages partitions by ensureLookupPartitions at
-- driver startup. The redundant idx_messages_lookup_messagehash is not
-- recreated: the primary key already covers messagehash as leading column.
DROP TABLE IF EXISTS messages_lookup;

CREATE TABLE messages_lookup (
   timestamp BIGINT NOT NULL,
   messageHash VARCHAR NOT NULL,
   CONSTRAINT messageIndexLookupTable PRIMARY KEY (messageHash, timestamp)
  ) PARTITION BY RANGE (timestamp);

-- Update to new version
UPDATE version SET version = 8 WHERE version = 7;

"""
