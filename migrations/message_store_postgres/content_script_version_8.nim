const ContentScriptVersion_8* = """

-- Recreate messages_lookup as a partitioned table (#3790): retention drops
-- hourly lookup partitions with their messages siblings instead of running
-- bulk DELETEs that bloat the indexes. Rows are rebuilt from the messages
-- partitions by ensureLookupPartitions. The old secondary indexes are not
-- recreated: the PK covers hash lookups, partition pruning covers time.
DROP TABLE IF EXISTS messages_lookup;

CREATE TABLE messages_lookup (
   timestamp BIGINT NOT NULL,
   messageHash VARCHAR NOT NULL,
   CONSTRAINT messageIndexLookupTable PRIMARY KEY (messageHash, timestamp)
  ) PARTITION BY RANGE (timestamp);

-- Update to new version
UPDATE version SET version = 8 WHERE version = 7;

"""
