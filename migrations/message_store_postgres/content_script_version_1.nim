const ContentScriptVersion_1* = """
CREATE TABLE IF NOT EXISTS messages (
   pubsubTopic VARCHAR NOT NULL,
   contentTopic VARCHAR NOT NULL,
   payload VARCHAR,
   version INTEGER NOT NULL,
   timestamp BIGINT NOT NULL,
   id VARCHAR NOT NULL,
   messageHash VARCHAR NOT NULL,
   storedAt BIGINT NOT NULL,
   CONSTRAINT messageIndex PRIMARY KEY (messageHash)
);

CREATE TABLE iF NOT EXISTS version (
   version INTEGER NOT NULL
);

INSERT INTO version (version) VALUES(1);

"""
