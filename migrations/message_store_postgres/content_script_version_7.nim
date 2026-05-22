const ContentScriptVersion_7* = """

-- Create lookup table
CREATE TABLE IF NOT EXISTS messages_lookup (
   timestamp BIGINT NOT NULL,
   messageHash VARCHAR NOT NULL
  );

-- Put data into lookup table
INSERT INTO messages_lookup (messageHash, timestamp) SELECT messageHash, timestamp from messages;

ALTER TABLE messages_lookup ADD CONSTRAINT messageIndexLookupTable PRIMARY KEY (messageHash, timestamp);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_messages_messagehash ON messages (messagehash);
CREATE INDEX IF NOT EXISTS idx_messages_timestamp ON messages (timestamp);
CREATE INDEX IF NOT EXISTS idx_messages_lookup_messagehash ON messages_lookup (messagehash);
CREATE INDEX IF NOT EXISTS idx_messages_lookup_timestamp ON messages_lookup (timestamp);

DROP INDEX IF EXISTS i_query_storedat;
DROP INDEX IF EXISTS i_query;

CREATE INDEX IF NOT EXISTS idx_query_pubsubtopic ON messages (pubsubTopic);
CREATE INDEX IF NOT EXISTS idx_query_contenttopic ON messages (contentTopic);

-- Update to new version
UPDATE version SET version = 7 WHERE version = 6;

"""
