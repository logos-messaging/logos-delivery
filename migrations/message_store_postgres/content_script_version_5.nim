const ContentScriptVersion_5* = """
CREATE INDEX IF NOT EXISTS i_query_storedAt ON messages (storedAt, id);

UPDATE version SET version = 5 WHERE version = 4;
"""
