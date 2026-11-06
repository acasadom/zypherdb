"""One application process using the installed zypherdb. Takes JSON commands on stdin, one per line."""
import faulthandler
import hashlib
import json
import os
import sys
import threading
import time

faulthandler.enable()
from zypherdb import Database  # noqa: E402

config = json.loads(sys.argv[1])
db = None
stop = threading.Event()
threads = []


def to_json(value):
    return json.loads(json.dumps(value, default=repr))


def digest():
    graph = db.export_graph()
    text = json.dumps(graph, sort_keys=True, default=repr).encode()
    return {"sha": hashlib.sha256(text).hexdigest(), "nodes": len(graph["nodes"]), "relationships": len(graph["relationships"])}


def stream(name, start, count, workers, ack_path, ryw=False, pace=0.0):
    """Unique writes; each outcome goes to `ack_path` right after the answer, unbuffered."""
    handle = os.open(ack_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND)
    lock = threading.Lock()
    next_seq = [start]

    def worker():
        while not stop.is_set():
            with lock:
                seq = next_seq[0]
                if seq >= start + count:
                    return
                next_seq[0] += 1
            line = None
            try:
                rows = db.query("CREATE (e:Event {stream: $s, seq: $q}) RETURN e.seq", s=name, q=seq)
                if rows != [[seq]]:
                    line = f"BADROWS {seq} {rows!r}"
                elif not rows.visible:
                    line = f"A {seq} invisible"
                else:
                    line = f"A {seq}"
                    if ryw:
                        seen = db.query("MATCH (e:Event {seq: $q}) WHERE e.stream = $s RETURN count(e)", s=name, q=seq)
                        if seen != [[1]]:
                            line = f"RYW {seq} {seen!r}"
            except Exception as error:
                kind = type(error).__name__
                code = {"MasterUnreachableError": "N", "OutcomeUnknownError": "U"}.get(kind, "E")
                line = f"{code} {seq} {kind} {str(error)[:150]!r}"
                time.sleep(0.02)
            os.write(handle, (line + "\n").encode())
            if pace:
                time.sleep(pace)

    for _ in range(workers):
        thread = threading.Thread(target=worker)
        thread.start()
        threads.append(thread)


def batches(name, start, count, ack_path, pace=0.0):
    """write_many of 5 statements: all or none must ever be seen."""
    handle = os.open(ack_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND)

    def worker():
        for seq in range(start, start + count):
            if stop.is_set():
                return
            statements = [("CREATE (:Batch {stream: $s, seq: $q, part: $p})", {"s": name, "q": seq, "p": part}) for part in range(5)]
            try:
                db.write_many(statements)
                line = f"A {seq}"
            except Exception as error:
                kind = type(error).__name__
                code = {"MasterUnreachableError": "N", "OutcomeUnknownError": "U"}.get(kind, "E")
                line = f"{code} {seq} {kind} {str(error)[:150]!r}"
                time.sleep(0.02)
            os.write(handle, (line + "\n").encode())
            if pace:
                time.sleep(pace)

    thread = threading.Thread(target=worker)
    thread.start()
    threads.append(thread)


def monitor(path):
    """Reader: batches never seen in part, counts never going back, reads never failing."""
    handle = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND)

    def worker():
        last_events = last_batches = reads = 0
        while not stop.is_set():
            try:
                [[events]] = db.query("MATCH (e:Event) RETURN count(e)")
                [[parts]] = db.query("MATCH (b:Batch) RETURN count(b)")
                reads += 1
                if parts % 5:
                    os.write(handle, f"TORN batch parts {parts}\n".encode())
                if events < last_events or parts < last_batches:
                    os.write(handle, f"BACKWARDS events {last_events}->{events} parts {last_batches}->{parts}\n".encode())
                last_events, last_batches = events, parts
            except Exception as error:
                os.write(handle, f"READERR {type(error).__name__} {str(error)[:150]!r}\n".encode())
            time.sleep(0.005)
        os.write(handle, f"READS {reads}\n".encode())

    thread = threading.Thread(target=worker)
    thread.start()
    threads.append(thread)


def handle(command):
    global db
    op = command.pop("op")
    if op == "open":
        db = Database(config["path"], **config.get("options", {}))
        return True
    if op == "query":
        rows = db.query(command["text"], command.get("params") or {})
        return {"rows": to_json(list(rows)), "visible": rows.visible}
    if op == "explain":
        return to_json(db.explain(command["text"]))
    if op == "status":
        return to_json(db.replication_status())
    if op == "last_lsn":
        return db.last_lsn
    if op == "wait_for":
        return db.wait_for(command["lsn"], command["timeout"])
    if op == "digest":
        return digest()
    if op == "check":
        return to_json(db.check())
    if op == "stream":
        stream(**command)
        return True
    if op == "batches":
        batches(**command)
        return True
    if op == "monitor":
        monitor(**command)
        return True
    if op == "stop":
        stop.set()
        for thread in threads:
            thread.join()
        threads.clear()
        stop.clear()
        return True
    if op == "close":
        db.close()
        return True
    raise ValueError(op)


for line in sys.stdin:
    command = json.loads(line)
    try:
        answer = {"ok": handle(command)}
    except BaseException as error:
        answer = {"error": type(error).__name__, "message": str(error)[:300]}
    sys.stdout.write(json.dumps(answer) + "\n")
    sys.stdout.flush()
