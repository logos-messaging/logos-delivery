const ContentScriptVersion_4* = """
ALTER TABLE messages ADD meta VARCHAR default null;

CREATE INDEX IF NOT EXISTS i_query ON messages (contentTopic, pubsubTopic, storedAt, id);

UPDATE version SET version = 4 WHERE version = 3;

"""
