const ContentScriptVersion_6* = """
-- we can drop the timestamp column because this data is also kept in the storedAt column
ALTER TABLE messages DROP COLUMN timestamp;

-- from now on we are only interested in the message timestamp
ALTER TABLE messages RENAME COLUMN storedAt TO timestamp;

-- Update to new version 
UPDATE version SET version = 6 WHERE version = 5;

"""
