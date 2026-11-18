#!/usr/bin/env python3
"""Turns test events into Kafka records in the format Debezium writes: a Confluent framing byte, the schema id (key 1,
value 2) and the JSON, one `key<TAB>value` line per record, ready for kafka-console-producer.

Reads TSV lines on stdin:  conversation_id <TAB> sequence <TAB> event_name <TAB> text [<TAB> actor [<TAB> occurred_at]]
Special lines:            TOMBSTONE <TAB> conversation_id          an empty value
                          RAW <TAB> conversation_id <TAB> text     a value that is not framed JSON (a poison record)
The account of a conversation is "acc-" + its id, so a test can tell conversations apart.
"""
import json
import sys


def frame(schema_id, body):
    return b"\x00" + schema_id.to_bytes(4, "big") + body


def key(cid):
    return frame(1, json.dumps({"conversation_id": cid}).encode())


PAYLOAD_FIELD = {"UserMessageSent": "text", "AgentMessageSent": "text", "GuardrailResponseSent": "response_text"}
CHAT = {"UserMessageSent": "user", "AgentMessageSent": "agent", "GuardrailResponseSent": "agent"}


def event(cid, seq, name, text, actor=None, occurred_at="2026-11-18T10:00:00.000000Z"):
    field = PAYLOAD_FIELD.get(name)
    payload = {field: text} if field else {"tool": text}
    return {
        "conversation_id": cid, "sequence": int(seq), "event_name": name, "event_version": 1,
        "payload": json.dumps(payload), "metadata": "{}", "correlation_id": "corr-" + cid,
        "id_yape_account": "acc-" + cid, "actor": actor or CHAT.get(name, "agent"), "flow": "p2p",
        "occurred_at": occurred_at,
    }


def main():
    out = sys.stdout.buffer
    for line in sys.stdin.read().splitlines():
        if not line.strip():
            continue
        f = line.split("\t")
        if f[0] == "TOMBSTONE":
            out.write(key(f[1]) + b"\t" + b"" + b"\n")
        elif f[0] == "RAW":
            out.write(key(f[1]) + b"\t" + f[2].encode() + b"\n")
        else:
            cid, seq, name, text = f[0], f[1], f[2], f[3]
            actor = f[4] if len(f) > 4 and f[4] else None
            when = f[5] if len(f) > 5 and f[5] else "2026-11-18T10:00:00.000000Z"
            out.write(key(cid) + b"\t" + frame(2, json.dumps(event(cid, seq, name, text, actor, when)).encode()) + b"\n")


if __name__ == "__main__":
    main()
