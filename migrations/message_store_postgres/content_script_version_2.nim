const ContentScriptVersion_2* = """
ALTER TABLE IF EXISTS messages_backup RENAME TO messages;
ALTER TABLE messages RENAME TO messages_backup;
ALTER TABLE messages_backup DROP CONSTRAINT messageIndex;

CREATE TABLE IF NOT EXISTS messages (
   pubsubTopic VARCHAR NOT NULL,
   contentTopic VARCHAR NOT NULL,
   payload VARCHAR,
   version INTEGER NOT NULL,
   timestamp BIGINT NOT NULL,
   id VARCHAR NOT NULL,
   messageHash VARCHAR NOT NULL,
   storedAt BIGINT NOT NULL,
   CONSTRAINT messageIndex PRIMARY KEY (messageHash, storedAt)
  ) PARTITION BY RANGE (storedAt);

DO $$
DECLARE
     min_storedAt numeric;
     max_storedAt numeric;
     min_storedAtSeconds integer = 0;
     max_storedAtSeconds integer = 0;
     partition_name TEXT;
     create_partition_stmt TEXT;
BEGIN
    SELECT MIN(storedAt) into min_storedAt
    FROM messages_backup;

    SELECT MAX(storedAt) into max_storedAt
    FROM messages_backup;

    min_storedAtSeconds := min_storedAt / 1000000000;
    max_storedAtSeconds := max_storedAt / 1000000000;

    partition_name := 'messages_' || min_storedAtSeconds || '_' || max_storedAtSeconds;
    create_partition_stmt := 'CREATE TABLE ' || partition_name ||
                            ' PARTITION OF messages FOR VALUES FROM (' ||
                            min_storedAt || ') TO (' || (max_storedAt + 1) || ')';
    IF min_storedAtSeconds > 0 AND max_storedAtSeconds > 0 THEN
    	EXECUTE create_partition_stmt USING partition_name, min_storedAt, max_storedAt;
    END IF;
END $$;

INSERT INTO messages (
                        pubsubTopic,
                        contentTopic,
                        payload,
                        version,
                        timestamp,
                        id,
                        messageHash,
                        storedAt
                     )
                SELECT pubsubTopic,
                       contentTopic,
                       payload,
                       version,
                       timestamp,
                       id,
                       messageHash,
                       storedAt
                   FROM messages_backup;

DROP TABLE messages_backup;

UPDATE version SET version = 2 WHERE version = 1;

"""
