"""Replication in real use: what a user installs, each node a process of its own, processes
killed, connections cut, and exact checks of what each write was answered. See "The real use test"
in docs/guide/contributing.md.

    python -m venv venv && venv/bin/pip install zypherdb-*.whl
    venv/bin/python -I tests/real_use/run.py              # all, about 8 minutes
    venv/bin/python -I tests/real_use/run.py s05 s07      # some

SEED picks the random choices, SOAK_SECONDS the length of the soak, REAL_TMP where the databases
go (the operating system's temporary directory by default): those of a scenario that fails are
kept. POSIX only (it kills with SIGKILL and reads `ps`). Nothing here imports zypherdb: only
node.py does.
"""
import json
import os
import queue
import random
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
PYTHON = sys.executable
TOKEN = "a-long-random-secret-for-this-test"
FAILS = []
NOTES = []
LIVE = []
current = ""


def note(text):
    NOTES.append((current, text))
    print(f"    {text}", flush=True)


def fail(text):
    FAILS.append((current, text))
    print(f"    FAIL {text}", flush=True)


def check(condition, text):
    if not condition:
        fail(text)
    return condition


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Node:
    def __init__(self, path, **options):
        self.path = path
        self.killed = False
        self.err_path = f"{path}.{time.monotonic_ns()}.stderr"
        self.err = open(self.err_path, "wb")
        self.process = subprocess.Popen([PYTHON, "-I", os.path.join(HERE, "node.py"), json.dumps({"path": path, "options": options})], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.err, cwd=HERE, text=True)
        self.answers = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()
        LIVE.append(self)
        self.call("open", timeout=60)

    def _read(self):
        for line in self.process.stdout:
            self.answers.put(json.loads(line))
        self.answers.put(None)

    def call(self, op, timeout=120, **args):
        self.process.stdin.write(json.dumps({"op": op, **args}) + "\n")
        self.process.stdin.flush()
        try:
            answer = self.answers.get(timeout=timeout)
        except queue.Empty:
            raise AssertionError(f"HANG: {op} on {os.path.basename(self.path)} did not answer in {timeout} s")
        if answer is None:
            raise AssertionError(f"process died during {op} on {os.path.basename(self.path)}: exit {self.process.poll()} stderr {self.stderr()[-400:]!r}")
        if "error" in answer:
            raise DbError(answer["error"], answer["message"])
        return answer["ok"]

    def query(self, text, **params):
        return self.call("query", text=text, params=params)["rows"]

    def status(self):
        return self.call("status")

    def lsn(self):
        return self.call("last_lsn")

    def stderr(self):
        with open(self.err_path, "rb") as handle:
            return handle.read().decode(errors="replace")

    def kill(self):
        self.killed = True
        self.process.send_signal(signal.SIGKILL)
        self.process.wait()
        self._done()

    def close(self, timeout=30):
        started = time.monotonic()
        self.call("close", timeout=timeout)
        self.process.stdin.close()
        try:
            code = self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            fail(f"process of {os.path.basename(self.path)} did not exit after close")
            self.process.kill()
            code = None
        check(code == 0, f"process of {os.path.basename(self.path)} exit code {code}")
        took = time.monotonic() - started
        check(took < 10, f"close of {os.path.basename(self.path)} took {took:.1f} s")
        self._done()

    def _done(self):
        if self in LIVE:
            LIVE.remove(self)
        self.err.close()
        text = self.stderr()
        check(not any(word in text for word in ("panic", "Fatal Python", "Segmentation", "Traceback", "assert")), f"stderr of {os.path.basename(self.path)}: {text[-600:]!r}")

    def rss_mb(self):
        return int(subprocess.run(["ps", "-o", "rss=", "-p", str(self.process.pid)], capture_output=True, text=True).stdout or 0) // 1024

    def fds(self):
        # Needs lsof.
        return len(subprocess.run(["lsof", "-p", str(self.process.pid)], capture_output=True, text=True).stdout.splitlines())


class DbError(Exception):
    def __init__(self, kind, message):
        super().__init__(f"{kind}: {message}")
        self.kind = kind


class Proxy:
    """TCP between a replica and its master; cuts (RST) and silent stalls on demand."""

    def __init__(self, target_port):
        self.target = target_port
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(32)
        self.port = self.listener.getsockname()[1]
        self.links = []
        self.lock = threading.Lock()
        self.stalled = False
        self.closed = False
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while not self.closed:
            try:
                client, _ = self.listener.accept()
            except OSError:
                return
            try:
                server = socket.create_connection(("127.0.0.1", self.target), timeout=2)
            except OSError:
                self._reset(client)
                continue
            with self.lock:
                self.links.append((client, server))
            threading.Thread(target=self._pump, args=(client, server), daemon=True).start()

    def _pump(self, client, server):
        try:
            while True:
                if self.stalled:
                    time.sleep(0.02)
                    if client.fileno() < 0:
                        return
                    continue
                readable, _, _ = select.select([client, server], [], [], 0.05)
                for source in readable:
                    data = source.recv(1 << 16)
                    if not data:
                        raise OSError
                    (server if source is client else client).sendall(data)
        except (OSError, ValueError):
            self._end(client, server)

    @staticmethod
    def _reset(one):
        try:
            one.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            one.close()
        except OSError:
            pass

    def _end(self, client, server):
        self._reset(client)
        self._reset(server)
        with self.lock:
            if (client, server) in self.links:
                self.links.remove((client, server))

    def cut(self):
        with self.lock:
            links = list(self.links)
        for client, server in links:
            try:
                client.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self._end(client, server)

    def close(self):
        self.closed = True
        self.listener.close()
        self.cut()


def wait_until(condition, timeout, text):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.02)
    fail(f"not within {timeout} s: {text}")
    return False


def converge(master, replicas, timeout=90):
    """All at the master's last change, same bytes of graph, sound indexes."""
    lsn = master.lsn()
    wanted = master.call("digest", timeout=300)
    verdict = master.call("check", timeout=300)
    check(verdict["ok"], f"master check: {verdict}")
    for replica in replicas:
        if not _wait(replica, lsn, timeout):
            fail(f"{os.path.basename(replica.path)} did not reach lsn {lsn}: {replica.status()}")
            continue
        got = replica.call("digest", timeout=300)
        check(got == wanted, f"{os.path.basename(replica.path)} differs from the master: {got} vs {wanted}")
        verdict = replica.call("check", timeout=300)
        check(verdict["ok"], f"{os.path.basename(replica.path)} check: {verdict}")
    return wanted


def _wait(replica, lsn, timeout):
    replica.process.stdin.write(json.dumps({"op": "wait_for", "lsn": lsn, "timeout": float(timeout)}) + "\n")
    replica.process.stdin.flush()
    try:
        answer = replica.answers.get(timeout=timeout + 30)
    except queue.Empty:
        raise AssertionError(f"HANG: wait_for on {os.path.basename(replica.path)}")
    if answer is None:
        raise AssertionError(f"{os.path.basename(replica.path)} died: {replica.stderr()[-400:]!r}")
    return answer.get("ok") is True


def read_acks(path):
    kinds = {}
    other = []
    if not os.path.exists(path):
        return kinds, other
    for line in open(path):
        parts = line.split()
        if parts[0] in ("A", "N", "U"):
            kinds.setdefault(parts[0], set()).add(int(parts[1]))
        else:
            other.append(line.strip())
    return kinds, other


def verify_stream(master, ack_paths, stream=None, label="Event"):
    """Exactly once: answered yes is there, answered 'did not run' is not, nothing twice."""
    rows = master.query(f"MATCH (e:{label}) RETURN e.seq, e.stream")
    present = {}
    for seq, name in rows:
        if stream is None or name == stream:
            present[seq] = present.get(seq, 0) + 1
    multiple = 5 if label == "Batch" else 1
    twice = [seq for seq, n in present.items() if n != multiple]
    check(not twice, f"{label}: written a wrong number of times: {twice[:10]} ({len(twice)})")
    answered = {"A": 0, "N": 0, "U": 0}
    for path in ack_paths:
        kinds, other = read_acks(path)
        check(not other, f"{os.path.basename(path)}: unexpected answers ({len(other)}): {other[:4]}")
        lost = [seq for seq in kinds.get("A", ()) if seq not in present]
        check(not lost, f"{label}: answered committed but LOST: {lost[:10]} ({len(lost)})")
        ghost = [seq for seq in kinds.get("N", ()) if seq in present]
        check(not ghost, f"{label}: answered 'did not run' but IS THERE: {ghost[:10]} ({len(ghost)})")
        for kind in answered:
            answered[kind] += len(kinds.get(kind, ()))
    return answered, len(present)


def verify_monitor(path):
    if not os.path.exists(path):
        fail("monitor wrote nothing")
        return
    bad = [line.strip() for line in open(path) if not line.startswith("READS")]
    reads = [line.split()[1] for line in open(path) if line.startswith("READS")]
    check(not bad, f"reader on the replica saw ({len(bad)}): {bad[:4]}")
    return reads


def index_events(master):
    master.query("CREATE INDEX event_seq FOR (e:Event) ON (e.seq)")


# --- Scenarios -----------------------------------------------------------------------------------


def s01_big_first_copy(tmp):
    """A database with real data; two replicas join by host name."""
    port = free_port()
    master = Node(f"{tmp}/m", serve=f"0.0.0.0:{port}", token=TOKEN)
    master.query("CREATE INDEX person_id FOR (p:Person) ON (p.id)")
    started = time.monotonic()
    people = 300_000
    master.query("UNWIND range(0, $n - 1) AS i CREATE (:Person {id: i, name: 'person ' + toString(i), age: i % 90, active: i % 2 = 0})", n=people)
    master.query("UNWIND range(0, $n - 1) AS i MATCH (a:Person {id: i}), (b:Person {id: (i * 7 + 1) % $n}) CREATE (a)-[:KNOWS {since: i % 30}]->(b)", n=people)
    note(f"load {people} nodes + relationships: {time.monotonic() - started:.1f} s")
    started = time.monotonic()
    replicas = [Node(f"{tmp}/r{i}", replicate_from=f"localhost:{port}", token=TOKEN, name=f"r{i}") for i in range(2)]
    digest = converge(master, replicas, 120)
    note(f"2 replicas copied and verified in {time.monotonic() - started:.1f} s: {digest['nodes']} nodes, {digest['relationships']} relationships")
    status = master.status()
    check(len(status["replicas"]) == 2, f"master sees {len(status['replicas'])} replicas")
    check(not os.path.exists(f"{tmp}/m/replication-copies") or not os.listdir(f"{tmp}/m/replication-copies"), "copies left behind in replication-copies")
    for query in ("MATCH (p:Person {id: 12345})-[:KNOWS]->(q) RETURN q.name", "MATCH (p:Person) WHERE p.age = 7 RETURN count(p)", "MATCH ()-[k:KNOWS]->() RETURN sum(k.since)"):
        answer = master.query(query)
        for replica in replicas:
            check(replica.query(query) == answer, f"{query}: differs on {replica.path}")
    for node in replicas + [master]:
        node.close()


def s02_live_writes_two_replicas(tmp):
    """Several threads write while two replicas follow and read."""
    port = free_port()
    master = Node(f"{tmp}/m", serve=f"127.0.0.1:{port}", token=TOKEN, durability="relaxed")
    index_events(master)
    replicas = [Node(f"{tmp}/r{i}", replicate_from=f"localhost:{port}", token=TOKEN, durability="relaxed") for i in range(2)]
    for i, replica in enumerate(replicas):
        replica.call("monitor", path=f"{tmp}/monitor{i}")
    master.call("stream", name="s", start=0, count=30_000, workers=4, ack_path=f"{tmp}/acks", ryw=True)
    master.call("batches", name="s", start=0, count=2_000, ack_path=f"{tmp}/backs")
    lag = []
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline and len(read_acks(f"{tmp}/acks")[0].get("A", ())) < 30_000:
        lsn = master.lsn()
        started = time.monotonic()
        _wait(replicas[0], lsn, 20)
        lag.append(time.monotonic() - started)
        time.sleep(0.2)
    master.call("stop", timeout=60)
    for replica in replicas:
        replica.call("stop")
    converge(master, replicas)
    answered, present = verify_stream(master, [f"{tmp}/acks"])
    verify_stream(master, [f"{tmp}/backs"], label="Batch")
    for i in range(2):
        verify_monitor(f"{tmp}/monitor{i}")
    note(f"{present} events, answers {answered}, worst time for a replica to catch up {max(lag) * 1000:.0f} ms")
    for node in replicas + [master]:
        node.close()


def s03_kill_replica(tmp):
    """kill -9 of a replica while writing, 5 times: no new copy needed, ends equal."""
    port = free_port()
    master = Node(f"{tmp}/m", serve=f"127.0.0.1:{port}", token=TOKEN, durability="relaxed")
    index_events(master)
    replica = Node(f"{tmp}/r", replicate_from=f"localhost:{port}", token=TOKEN, durability="relaxed")
    master.call("stream", name="s", start=0, count=10_000_000, workers=2, ack_path=f"{tmp}/acks", pace=0.001)
    copies = 0
    for _ in range(5):
        time.sleep(random.uniform(0.5, 2))
        replica.kill()
        time.sleep(random.uniform(0, 1))
        replica = Node(f"{tmp}/r", replicate_from=f"localhost:{port}", token=TOKEN, durability="relaxed")
        check(replica.call("check", timeout=120)["ok"], "replica unsound right after kill -9")
        for _ in range(200):
            phase = replica.status()["phase"]
            copies += phase == "copying"
            if phase == "streaming":
                break
            time.sleep(0.01)
    master.call("stop", timeout=60)
    converge(master, [replica])
    answered, present = verify_stream(master, [f"{tmp}/acks"])
    check(copies == 0, f"a killed replica needed a new copy ({copies} samples copying)")
    note(f"{present} events, answers {answered}")
    replica.close()
    master.close()


def s04_kill_master(tmp):
    """kill -9 of the master that writes, 6 times, each durability: nothing answered is lost."""
    for durability in ("full", "relaxed", "deferred"):
        port = free_port()
        path = f"{tmp}/m-{durability}"
        options = dict(serve=f"127.0.0.1:{port}", token=TOKEN, durability=durability)
        master = Node(path, **options)
        index_events(master)
        replica = Node(f"{tmp}/r-{durability}", replicate_from=f"localhost:{port}", token=TOKEN)
        replica.call("monitor", path=f"{tmp}/monitor-{durability}")
        start = 0
        for _ in range(6):
            master.call("stream", name="s", start=start, count=1_000_000, workers=3, ack_path=f"{tmp}/acks-{durability}", pace=0.0005)
            master.call("batches", name="s", start=start, count=1_000_000, ack_path=f"{tmp}/backs-{durability}", pace=0.001)
            start += 1_000_000
            time.sleep(random.uniform(0.3, 1.2))
            master.kill()
            master = Node(path, **options)
            check(master.call("check", timeout=120)["ok"], f"master unsound right after kill -9 ({durability})")
        answered, present = verify_stream(master, [f"{tmp}/acks-{durability}"])
        verify_stream(master, [f"{tmp}/backs-{durability}"], label="Batch")
        replica.call("stop")
        converge(master, [replica])
        verify_monitor(f"{tmp}/monitor-{durability}")
        note(f"{durability}: {present} events after 6 kills, answers {answered}")
        replica.close()
        master.close()


def s05_standby_takeover(tmp):
    """Two processes with the master's role: kill the one running replication."""
    port = free_port()
    options = dict(serve=f"127.0.0.1:{port}", token=TOKEN, durability="relaxed")
    first = Node(f"{tmp}/m", **options)
    index_events(first)
    second = Node(f"{tmp}/m", **options)
    check(second.status()["standby"] is True, "second process is not standing by")
    replica = Node(f"{tmp}/r", replicate_from=f"localhost:{port}", token=TOKEN, durability="relaxed")
    first.call("stream", name="a", start=0, count=1_000_000, workers=2, ack_path=f"{tmp}/acks1", pace=0.001)
    second.call("stream", name="b", start=0, count=1_000_000, workers=2, ack_path=f"{tmp}/acks2", pace=0.001)
    time.sleep(1.5)
    first.kill()
    started = time.monotonic()
    wait_until(lambda: second.status()["standby"] is False, 5, "the standby took over")
    note(f"takeover in {time.monotonic() - started:.2f} s")
    copying = 0
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        copying += replica.status()["phase"] == "copying"
        time.sleep(0.01)
    check(copying == 0, "the replica needed a new copy after a takeover")
    second.call("stop", timeout=60)
    converge(second, [replica])
    answered_a, present_a = verify_stream(second, [f"{tmp}/acks1"], stream="a")
    answered_b, present_b = verify_stream(second, [f"{tmp}/acks2"], stream="b")
    note(f"killed writer {answered_a}, surviving writer {answered_b}")
    replica.close()
    second.close()


def s06_forwarded_writes_master_dies(tmp):
    """Writes through a replica while the master is killed and returns: exact outcomes."""
    port = free_port()
    options = dict(serve=f"127.0.0.1:{port}", token=TOKEN, durability="relaxed")
    master = Node(f"{tmp}/m", **options)
    index_events(master)
    master.query("CREATE (:Seed)")
    replica = Node(f"{tmp}/r", replicate_from=f"localhost:{port}", token=TOKEN, durability="relaxed", forward_writes=True, forward_timeout=3.0)
    _wait(replica, master.lsn(), 20)
    replica.call("stream", name="s", start=0, count=1_000_000, workers=6, ack_path=f"{tmp}/acks", ryw=True)
    replica.call("batches", name="s", start=0, count=1_000_000, ack_path=f"{tmp}/backs")
    replica.call("monitor", path=f"{tmp}/monitor")
    for _ in range(4):
        time.sleep(random.uniform(1, 2))
        master.kill()
        time.sleep(random.uniform(0.2, 4))
        master = Node(f"{tmp}/m", **options)
    time.sleep(2)
    replica.call("stop", timeout=120)
    answered, present = verify_stream(master, [f"{tmp}/acks"])
    verify_stream(master, [f"{tmp}/backs"], label="Batch")
    converge(master, [replica])
    verify_monitor(f"{tmp}/monitor")
    check(answered["A"] > 100, f"few writes went through: {answered}")
    note(f"{present} events, answers {answered}")
    replica.close()
    master.close()


def s07_network_cuts(tmp):
    """Connections reset and silent stalls between replica and master, with writes both ways."""
    port = free_port()
    master = Node(f"{tmp}/m", serve=f"127.0.0.1:{port}", token=TOKEN, durability="relaxed")
    index_events(master)
    master.query("CREATE (:Seed)")
    proxy = Proxy(port)
    replica = Node(f"{tmp}/r", replicate_from=f"127.0.0.1:{proxy.port}", token=TOKEN, durability="relaxed", forward_writes=True, forward_timeout=3.0)
    _wait(replica, master.lsn(), 30)
    master.call("stream", name="m", start=0, count=10_000_000, workers=2, ack_path=f"{tmp}/macks", pace=0.001)
    replica.call("stream", name="r", start=0, count=10_000_000, workers=4, ack_path=f"{tmp}/racks", ryw=True, pace=0.001)
    replica.call("monitor", path=f"{tmp}/monitor")
    cuts = stalls = 0
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        time.sleep(random.uniform(0.2, 2))
        if random.random() < 0.15:
            proxy.stalled = True
            time.sleep(random.uniform(1, 8))
            proxy.stalled = False
            stalls += 1
        else:
            proxy.cut()
            cuts += 1
    master.call("stop", timeout=60)
    replica.call("stop", timeout=120)
    converge(master, [replica])
    answered_m, _ = verify_stream(master, [f"{tmp}/macks"], stream="m")
    answered_r, present_r = verify_stream(master, [f"{tmp}/racks"], stream="r")
    verify_monitor(f"{tmp}/monitor")
    check(answered_r["A"] > 100, f"few forwarded writes went through: {answered_r}")
    note(f"{cuts} cuts, {stalls} stalls; on the master {answered_m}; forwarded {answered_r}")
    replica.close()
    proxy.close()
    master.close()


def s08_everything_replicates(tmp):
    """What the language can write arrives as it was: schema, types, updates, deletes, large values."""
    port = free_port()
    master = Node(f"{tmp}/m", serve=f"127.0.0.1:{port}", token=TOKEN)
    replica = Node(f"{tmp}/r", replicate_from=f"localhost:{port}", token=TOKEN, forward_writes=True, forward_timeout=30.0)
    for statement in (
        "CREATE INDEX door_id FOR (d:Door) ON (d.id)",
        "CREATE CONSTRAINT card_number FOR (c:Card) REQUIRE c.number IS UNIQUE",
        "CREATE FULLTEXT INDEX notes FOR (n:Note) ON EACH [n.text]",
        "UNWIND range(1, 1000) AS i CREATE (:Door {id: i, zone: 'z' + toString(i % 10), opened: datetime('2026-01-01T10:00:00Z'), day: date('2026-03-04'), span: duration('P1DT2H'), when: localtime('10:11:12'), price: i * 1.5, tags: ['a', 'b'], ok: i % 2 = 0, doc: {a: 1, b: {c: 'x'}}})",
        "UNWIND range(1, 100) AS i CREATE (:Card {number: i})",
        "CREATE (:Note {text: 'la puerta principal estaba abierta'}), (:Note {text: 'the main doors were closed'})",
        "MATCH (d:Door) WHERE d.id <= 100 MATCH (c:Card {number: d.id}) CREATE (c)-[:OPENS {at: date('2026-05-05'), n: d.id}]->(d)",
        "MATCH (d:Door) WHERE d.id % 3 = 0 SET d.painted = true, d:Red",
        "MATCH (d:Door) WHERE d.id % 5 = 0 REMOVE d.tags",
        "MATCH (d:Door) WHERE d.id % 7 = 0 DETACH DELETE d",
        "MATCH (c:Card)-[o:OPENS]->() WHERE o.n % 2 = 0 DELETE o",
        "CREATE (:Big {text: $large})",
        "MERGE (a:Thing {k: 1}) ON CREATE SET a.made = true MERGE (a)-[:SELF]->(a)",
    ):
        params = {"large": "ñ" * (6 << 20)} if "$large" in statement else {}
        master.query(statement, **params)
    # The same through the replica.
    _wait(replica, master.lsn(), 60)
    replica_row = replica.call("query", text="CREATE (:Door {id: 5000, via: 'replica'}) RETURN 1")
    check(replica_row["rows"] == [[1]], f"forwarded write answered {replica_row}")
    try:
        replica.query("CREATE (:Card {number: 1})")
        fail("a forwarded write broke a unique constraint")
    except DbError as error:
        check(error.kind == "ConstraintViolationError", f"forwarded constraint violation came as {error}")
    _wait(replica, master.lsn(), 30)
    for query in (
        "MATCH (d:Door) RETURN count(d), sum(d.price), collect(DISTINCT d.zone)[0..3]",
        "MATCH (d:Door {id: 11}) RETURN d",
        "MATCH (d:Door {id: 5000}) RETURN d.via",
        "MATCH (d:Red) RETURN count(d)",
        "MATCH (c:Card)-[o:OPENS]->(d) RETURN count(o), sum(o.n), min(o.at)",
        "MATCH (d:Door) WHERE d.tags IS NULL RETURN count(d)",
        "MATCH (b:Big) RETURN size(b.text), substring(b.text, 0, 3)",
        "MATCH (a:Thing)-[:SELF]->(a) RETURN a.made",
        "CALL db.index.fulltext.queryNodes('notes', 'puerta') YIELD node RETURN node.text",
        "SHOW INDEXES",
        "SHOW CONSTRAINTS",
    ):
        wanted = master.query(query)
        check(replica.query(query) == wanted, f"{query}: replica differs: {str(replica.query(query))[:200]} vs {str(wanted)[:200]}")
        if query.startswith("CALL"):
            check(wanted == [["la puerta principal estaba abierta"]], f"fulltext found {wanted}")
    plan = json.dumps(replica.call("explain", text="MATCH (d:Door {id: 11}) RETURN d"))
    check("door_id" in plan or "ndex" in plan, f"the replica's plan does not use the index: {plan[:300]}")
    converge(master, [replica])
    # A second replica joining after all that.
    late = Node(f"{tmp}/late", replicate_from=f"localhost:{port}", token=TOKEN)
    converge(master, [late])
    for node in (late, replica, master):
        node.close()


def s09_wrong_use(tmp):
    """What a user gets wrong gets told, not silence or damage."""
    port = free_port()
    master = Node(f"{tmp}/m", serve=f"127.0.0.1:{port}", token=TOKEN)
    master.query("CREATE (:A)")

    wrong = Node(f"{tmp}/wrong", replicate_from=f"localhost:{port}", token="another-secret-of-the-same-length")
    wait_until(lambda: wrong.status()["last_refusal"] == "token", 20, "wrong token told in status")
    check(wrong.query("MATCH (n) RETURN count(n)") == [[0]], "a wrong token got data")
    wrong.close()

    clear = Node(f"{tmp}/clear", replicate_from=f"localhost:{port}", token=TOKEN, encrypted=False)
    wait_until(lambda: clear.status()["last_refusal"] == "encryption", 20, "encryption mismatch told in status")
    clear.close()

    replica = Node(f"{tmp}/r", replicate_from=f"localhost:{port}", token=TOKEN)
    _wait(replica, master.lsn(), 20)
    try:
        replica.query("CREATE (:B)")
        fail("a replica without forward_writes accepted a write")
    except DbError as error:
        check("is a replica" in str(error), f"write on a replica came as {error}")
    replica.close()

    plain = Node(f"{tmp}/plain")
    plain.query("CREATE (:Mine)")
    plain.close()
    try:
        Node(f"{tmp}/plain", replicate_from=f"localhost:{port}", token=TOKEN)
        fail("a database holding data was opened as a replica")
    except DbError as error:
        check("holds data" in str(error), f"opening a database with data as a replica: {error}")
    finally:
        for node in list(LIVE):
            if node.path.endswith("/plain"):
                node.process.kill()
                LIVE.remove(node)
    probe = Node(f"{tmp}/plain")
    check(probe.query("MATCH (n:Mine) RETURN count(n)") == [[1]], "refusing to follow damaged the data")
    probe.close()

    # A replica started before its master exists.
    later_port = free_port()
    early = Node(f"{tmp}/early", replicate_from=f"localhost:{later_port}", token=TOKEN)
    check(early.status()["phase"] == "connecting", "a replica with no master is not connecting")
    time.sleep(2)
    late_master = Node(f"{tmp}/late", serve=f"127.0.0.1:{later_port}", token=TOKEN)
    late_master.query("CREATE (:A)")
    converge(late_master, [early], 30)
    early.close()
    late_master.close()
    master.close()


def s10_replica_left_behind(tmp):
    """Replica away past the 512 MiB change log: a new copy, serving reads all along."""
    port = free_port()
    master = Node(f"{tmp}/m", serve=f"127.0.0.1:{port}", token=TOKEN, durability="deferred")
    index_events(master)
    master.query("CREATE (:Event {seq: -1, stream: 'first'})")
    replica = Node(f"{tmp}/r", replicate_from=f"localhost:{port}", token=TOKEN)
    converge(master, [replica])
    replica.close()
    value = "x" * (1 << 20)
    started = time.monotonic()
    for i in range(700):
        master.query("CREATE (:Blob {i: $i, v: $v})", i=i, v=value)
    note(f"700 MiB written while away, {time.monotonic() - started:.1f} s")
    replica = Node(f"{tmp}/r", replicate_from=f"localhost:{port}", token=TOKEN)
    replica.call("monitor", path=f"{tmp}/monitor")
    saw_copying = False
    started = time.monotonic()
    deadline = started + 90
    lsn = master.lsn()
    while time.monotonic() < deadline:
        status = replica.status()
        saw_copying = saw_copying or status["phase"] == "copying"
        if status["applied_lsn"] >= lsn:
            break
        time.sleep(0.02)
    note(f"caught up in {time.monotonic() - started:.1f} s, new copy seen: {saw_copying}")
    replica.call("stop")
    converge(master, [replica], 60)
    verify_monitor(f"{tmp}/monitor")
    check(not os.path.exists(f"{tmp}/m/replication-copies") or not os.listdir(f"{tmp}/m/replication-copies"), "copy left behind")
    replica.close()
    master.close()


def s11_whole_restart(tmp):
    """Everything stops in order and starts in the other: replica serves meanwhile, no new copy."""
    port = free_port()
    master_options = dict(serve=f"127.0.0.1:{port}", token=TOKEN)
    replica_options = dict(replicate_from=f"localhost:{port}", token=TOKEN)
    master = Node(f"{tmp}/m", **master_options)
    master.query("UNWIND range(1, 10000) AS i CREATE (:A {i: i})")
    replica = Node(f"{tmp}/r", **replica_options)
    converge(master, [replica])
    for _ in range(3):
        master.close()
        check(replica.query("MATCH (a:A) RETURN count(a) > 0") == [[True]], "replica does not read with its master down")
        replica.close()
        replica = Node(f"{tmp}/r", **replica_options)
        check(replica.query("MATCH (a:A) RETURN count(a) > 0") == [[True]], "replica does not read when opened with its master down")
        master = Node(f"{tmp}/m", **master_options)
        master.query("CREATE (:A {i: 0})")
        copying = 0
        deadline = time.monotonic() + 5
        while replica.status()["phase"] != "streaming" and time.monotonic() < deadline:
            copying += replica.status()["phase"] == "copying"
            time.sleep(0.01)
        check(copying == 0, "a whole restart needed a new copy")
        converge(master, [replica])
    replica.close()
    master.close()


def s12_process_exit(tmp):
    """An application that just ends (no close), or is told to end, ends."""
    port = free_port()
    code = """
import sys, threading
from zypherdb import Database
db = Database(sys.argv[1], serve="127.0.0.1:%d", token="%s")
db.query("CREATE (:A)")
threading.Thread(target=lambda: db.query("MATCH (n) RETURN count(n)")).start()
print("done", flush=True)
""" % (port, TOKEN)
    started = time.monotonic()
    try:
        ran = subprocess.run([PYTHON, "-I", "-c", code, f"{tmp}/m"], capture_output=True, text=True, timeout=20, cwd=HERE)
        check(ran.returncode == 0 and "done" in ran.stdout, f"master exit without close: {ran.returncode} {ran.stderr[-300:]}")
        note(f"master ended without close in {time.monotonic() - started:.2f} s")
    except subprocess.TimeoutExpired:
        fail("a master process that ends without close hangs")
    master = Node(f"{tmp}/m", serve=f"127.0.0.1:{port}", token=TOKEN)
    code = """
import sys
from zypherdb import Database
db = Database(sys.argv[1], replicate_from="localhost:%d", token="%s", forward_writes=True)
db.wait_for(int(sys.argv[2]), 20)
print(db.query("CREATE (:B) RETURN 1"), flush=True)
""" % (port, TOKEN)
    started = time.monotonic()
    try:
        ran = subprocess.run([PYTHON, "-I", "-c", code, f"{tmp}/r", str(master.lsn())], capture_output=True, text=True, timeout=30, cwd=HERE)
        check(ran.returncode == 0 and "[[1]]" in ran.stdout, f"replica exit without close: {ran.returncode} {ran.stdout} {ran.stderr[-300:]}")
        note(f"replica ended without close in {time.monotonic() - started:.2f} s")
    except subprocess.TimeoutExpired:
        fail("a replica process that ends without close hangs")
    # SIGTERM and SIGINT, as a service manager or Ctrl-C.
    for signum, label in ((signal.SIGTERM, "SIGTERM"), (signal.SIGINT, "SIGINT")):
        code = """
import sys, time
from zypherdb import Database
db = Database(sys.argv[1], replicate_from="localhost:%d", token="%s")
print("up", flush=True)
time.sleep(60)
""" % (port, TOKEN)
        process = subprocess.Popen([PYTHON, "-I", "-c", code, f"{tmp}/r"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, cwd=HERE)
        process.stdout.readline()
        time.sleep(0.5)
        process.send_signal(signum)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            fail(f"a replica process does not end on {label}")
            process.kill()
    replica = Node(f"{tmp}/r", replicate_from=f"localhost:{port}", token=TOKEN)
    converge(master, [replica])
    check(master.query("MATCH (n:B) RETURN count(n)") == [[1]], "the write before exit is missing")
    replica.close()
    master.close()


def s13_soak(tmp):
    """Minutes of everything at once: does memory or file descriptors grow, does lag stay bounded."""
    port = free_port()
    master = Node(f"{tmp}/m", serve=f"127.0.0.1:{port}", token=TOKEN)
    index_events(master)
    master.query("CREATE (:Seed)")
    proxy = Proxy(port)
    replica = Node(f"{tmp}/r", replicate_from=f"127.0.0.1:{proxy.port}", token=TOKEN, forward_writes=True, forward_timeout=3.0)
    steady = Node(f"{tmp}/r2", replicate_from=f"localhost:{port}", token=TOKEN)
    _wait(replica, master.lsn(), 30)
    _wait(steady, master.lsn(), 30)
    master.call("stream", name="m", start=0, count=100_000_000, workers=2, ack_path=f"{tmp}/macks", pace=0.002)
    replica.call("stream", name="r", start=0, count=100_000_000, workers=2, ack_path=f"{tmp}/racks", pace=0.002)
    steady.call("monitor", path=f"{tmp}/monitor")
    total = float(os.environ.get("SOAK_SECONDS", "150"))
    began = time.monotonic()
    samples = []
    cuts = 0
    worst_lag = 0.0
    while time.monotonic() - began < total:
        time.sleep(random.uniform(1, 4))
        proxy.cut()
        cuts += 1
        lsn = master.lsn()
        started = time.monotonic()
        if not _wait(steady, lsn, 30):
            fail(f"steady replica did not reach {lsn} in 30 s")
        worst_lag = max(worst_lag, time.monotonic() - started)
        if not samples or time.monotonic() - samples[-1][0] > 30:
            samples.append((time.monotonic(), master.rss_mb(), master.fds(), replica.rss_mb(), replica.fds(), steady.rss_mb(), steady.fds()))
    master.call("stop", timeout=60)
    replica.call("stop", timeout=120)
    steady.call("stop")
    converge(master, [replica, steady])
    answered_m, present_m = verify_stream(master, [f"{tmp}/macks"], stream="m")
    answered_r, present_r = verify_stream(master, [f"{tmp}/racks"], stream="r")
    verify_monitor(f"{tmp}/monitor")
    note(f"{total:.0f} s, {cuts} cuts, {present_m + present_r} writes; forwarded {answered_r}; worst steady-replica catch-up {worst_lag * 1000:.0f} ms")
    for sample in samples[1:]:
        note(f"t={sample[0] - began:4.0f}s RSS MB master {sample[1]} cut-replica {sample[3]} steady {sample[5]}; fds {sample[2]} {sample[4]} {sample[6]}")
    if len(samples) >= 3:
        check(samples[-1][4] - samples[1][4] <= 8, f"file descriptors grow on the replica cut off: {samples[1][4]} to {samples[-1][4]}")
        check(samples[-1][2] - samples[1][2] <= 8, f"file descriptors grow on the master: {samples[1][2]} to {samples[-1][2]}")
    for node in (steady, replica):
        node.close()
    proxy.close()
    master.close()



def memory_of(node):
    if sys.platform != "darwin":
        for line in open(f"/proc/{node.process.pid}/status"):
            if line.startswith("RssAnon"):
                return line.split(":")[1].strip()
        return "?"
    out = subprocess.run(["footprint", "-p", str(node.process.pid)], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "phys_footprint:" in line:
            return line.split(":")[1].strip()
    return "?"


def s14_memory(tmp):
    """Nothing grows in data, yet many changes pass (past the change log's size): memory stays flat."""
    port = free_port()
    master = Node(f"{tmp}/m", serve=f"127.0.0.1:{port}", token=TOKEN, durability="deferred")
    replica = Node(f"{tmp}/r", replicate_from=f"localhost:{port}", token=TOKEN, durability="deferred", forward_writes=True)
    master.query("CREATE INDEX spot_i FOR (s:Spot) ON (s.i)")
    master.query("UNWIND range(0, 999) AS i CREATE (:Spot {i: i})")
    _wait(replica, master.lsn(), 20)
    value = "x" * 4000
    began = time.monotonic()
    rounds = 0
    last = 0
    while time.monotonic() - began < 100:
        for _ in range(2000):
            rounds += 1
            master.query("MATCH (s:Spot {i: $i}) SET s.v = $v, s.n = $n", i=rounds % 1000, v=value, n=rounds)
        for _ in range(20):
            replica.query("MATCH (s:Spot {i: 1}) SET s.w = $n", n=rounds)
        _wait(replica, master.lsn(), 30)
        if time.monotonic() - last > 12:
            last = time.monotonic()
            note(f"t={last - began:4.0f}s {rounds} updates; master {memory_of(master)} rss {master.rss_mb()} MB; replica {memory_of(replica)} rss {replica.rss_mb()} MB; fds {master.fds()} {replica.fds()}")
    converge(master, [replica])
    replica.close()
    master.close()


def s15_replica_durability_costs_more(tmp):
    """A replica whose commits cost more than its master's keeps up, and survives a kill while behind."""
    port = free_port()
    master = Node(f"{tmp}/m", serve=f"127.0.0.1:{port}", token=TOKEN, durability="relaxed")
    index_events(master)
    replica = Node(f"{tmp}/r", replicate_from=f"localhost:{port}", token=TOKEN, durability="full")
    replica.call("monitor", path=f"{tmp}/monitor")
    master.call("stream", name="s", start=0, count=100_000_000, workers=4, ack_path=f"{tmp}/acks")
    lags = []
    for _ in range(6):
        time.sleep(2)
        lags.append(master.lsn() - replica.status()["applied_lsn"])
    check(max(lags[2:]) < 200, f"the replica falls behind: {lags}")
    note(f"lag every 2 s: {lags}")
    master.call("stop", timeout=60)
    replica.call("stop")
    verify_monitor(f"{tmp}/monitor")
    converge(master, [replica])

    # Far behind, then killed while it applies in groups.
    master.close()
    master = Node(f"{tmp}/m", serve=f"127.0.0.1:{port}", token=TOKEN, durability="deferred")
    master.call("stream", name="s", start=100_000_000, count=100_000_000, workers=4, ack_path=f"{tmp}/acks2")
    for _ in range(4):
        time.sleep(1)
        replica.kill()
        replica = Node(f"{tmp}/r", replicate_from=f"localhost:{port}", token=TOKEN, durability="full")
        check(replica.call("check", timeout=120)["ok"], "replica unsound after a kill while behind")
    time.sleep(1)
    master.call("stop", timeout=60)
    started = time.monotonic()
    converge(master, [replica], 120)
    answered, present = verify_stream(master, [f"{tmp}/acks2"], stream="s")
    note(f"{present} events; {answered}; caught up in {time.monotonic() - started:.1f} s")
    replica.close()
    master.close()


SCENARIOS = [s01_big_first_copy, s02_live_writes_two_replicas, s03_kill_replica, s04_kill_master, s05_standby_takeover, s06_forwarded_writes_master_dies, s07_network_cuts, s08_everything_replicates, s09_wrong_use, s10_replica_left_behind, s11_whole_restart, s12_process_exit, s13_soak, s14_memory, s15_replica_durability_costs_more]


def main():
    global current
    names = sys.argv[1:]
    random.seed(int(os.environ.get("SEED", "1")))
    installed = subprocess.run([PYTHON, "-I", "-c", "import zypherdb; print(zypherdb.__file__)"], capture_output=True, text=True, cwd=HERE).stdout.strip()
    if "site-packages" not in installed:
        sys.exit(f"install the wheel in this Python first (zypherdb found: {installed or 'none'})")
    print("testing:", installed, flush=True)
    results = []
    for scenario in SCENARIOS:
        if names and not any(scenario.__name__.startswith(name) for name in names):
            continue
        current = scenario.__name__
        print(f"== {current}: {scenario.__doc__.strip()}", flush=True)
        tmp = tempfile.mkdtemp(prefix="real-", dir=os.environ.get("REAL_TMP"))
        before = len(FAILS)
        started = time.monotonic()
        try:
            scenario(tmp)
        except BaseException:
            FAILS.append((current, traceback.format_exc()[-900:]))
            print(FAILS[-1][1], flush=True)
        for node in list(LIVE):
            for line in node.stderr()[-500:].splitlines()[-4:]:
                print("    stderr:", line, flush=True)
            node.process.kill()
            LIVE.remove(node)
        ok = len(FAILS) == before
        results.append((current, ok, time.monotonic() - started))
        print(f"   {'PASS' if ok else 'FAIL'} in {time.monotonic() - started:.1f} s", flush=True)
        if ok:
            shutil.rmtree(tmp, ignore_errors=True)
        else:
            print(f"   kept {tmp}", flush=True)
    print("\nSUMMARY", flush=True)
    for name, ok, took in results:
        print(f"{'PASS' if ok else 'FAIL'} {name} ({took:.0f} s)", flush=True)
    os._exit(1 if FAILS else 0)


main()
