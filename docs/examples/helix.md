# A day at Helix Biolabs

`examples/helix/` is the access-control system of the [tutorial](../tutorial/01-getting-started)
as a program: the site and its 26 people loaded from files, the door controller, the monitor, and
a simulated Tuesday.

- The main process plays the card readers. It follows every badge's itinerary for the day through
  the door controller.
- A second process runs the monitor, which checks the rules no door can enforce every five
  simulated minutes.

The two processes share nothing but the database directory, as a real controller and monitor
would. The day contains a case of every rule: badges, bans, grants and their hours, training,
closing times, minimum and maximum occupancy, rooms that must never be empty, visitors' escorts and
the time limit in high containment.

## Running it

From the repository root, with the package installed (`pip install acmedb`) or built from source
(`make python`, then `PYTHONPATH=python`):

```bash
python -m examples.helix.simulate
```

```text
Helix Biolabs, Tuesday 11 March 2025: 8 rooms, 26 people, 27 badges, 134 movements planned

06:55 refused  Emeka Nwosu         Sequencing Lab    outside hours
07:10 refused  Lars Becker         Animal Holding    training missing
07:55 refused  Chen Wei            Lobby             badge not valid
08:30 refused  Kemi Adeyemi        BSL-3 Lab         training missing
10:00 refused  Tomás Novak         Sequencing Lab    room full
10:00 refused  Marta Gil           Lobby             badge not valid
10:10 refused  Sara Lindgren       BSL-3 Lab         room full
10:10 refused  Yusuf Demir         BSL-3 Lab         room full
10:30 refused  Ines Moreau         Sequencing Lab    no access
10:30 refused  Gustavo Pérez       Airlock           barred from the zone
10:40 refused  Hiro Tanaka         Sequencing Lab    no access
11:00 ALARM    unescorted visitor  Seminar Room      Ines Moreau
11:45 cleared  unescorted visitor  Seminar Room
12:35 ALARM    overstay            BSL-3 Lab         Dalia Haddad, Joon Park
12:40 ALARM    alone               BSL-3 Lab         Nadia Petrova
12:40 cleared  overstay            BSL-3 Lab
12:50 cleared  alone               BSL-3 Lab
13:00 ALARM    unstaffed           Vivarium Control
13:30 cleared  unstaffed           Vivarium Control
14:10 refused  Nadia Petrova       BSL-3 Lab         room full
15:00 site     a sequencer is serviced: the Sequencing Lab takes 3
15:00 ALARM    over capacity       Sequencing Lab    Aiko Sato, Chen Wei, Emeka Nwosu, Mia Schulz, Rafael Costa
15:40 refused  Priya Raman         Sequencing Lab    room full
15:45 site     the service is done: the Sequencing Lab takes 5 again
15:45 cleared  over capacity       Sequencing Lab
18:00 ALARM    after closing       BSL-3 Lab         Sara Lindgren, Yusuf Demir
18:10 ALARM    overstay            BSL-3 Lab         Sara Lindgren, Yusuf Demir
18:20 cleared  after closing       BSL-3 Lab
18:20 cleared  overstay            BSL-3 Lab

134 swipes; refused: room full 5, badge not valid 2, no access 2, training missing 2, barred from the zone 1, outside hours 1

Alarms:
  11:00-11:45 unescorted visitor  Seminar Room
  12:35-12:40 overstay            BSL-3 Lab
  12:40-12:50 alone               BSL-3 Lab
  13:00-13:30 unstaffed           Vivarium Control
  15:00-15:45 over capacity       Sequencing Lab
  18:00-18:20 after closing       BSL-3 Lab
  18:10-18:20 overstay            BSL-3 Lab

Where everyone was at 11:40, from the log:
  BSL-3 Lab         Ada Okafor, Dalia Haddad, Joon Park, Nadia Petrova
  Genomics Office   Bruno Lindqvist, Gustavo Pérez, Sofia Marín, Tomás Novak
  Seminar Room      Ines Moreau, Kemi Adeyemi, Sara Lindgren, Yusuf Demir
  Sequencing Lab    Aiko Sato, Chen Wei, Emeka Nwosu, Mia Schulz, Rafael Costa
  Vivarium Control  Fatima Rossi, Olga Ivanova

Still inside at 19:00:
  Vivarium Control  Pedro Alves
```

The output lists what needed attention, in time order:

- the swipes a door **refused**, with the rule that refused them;
- the **alarms** the monitor raised and cleared;
- the changes the facilities team made to the **site**.

The end of the day gives the totals, the alarm history and two views of where people were. The
first view is rebuilt from the log alone, for a moment in the past; the second is the positions
the controllers keep current.

Options:

- `--database DIR` keeps the database in `DIR`, which must be new, for you to query afterwards;
- `--every MINUTES` changes how often the monitor checks;
- `--verbose` also prints every door that opened.

## The pieces

| File | What it is |
| --- | --- |
| `site.json` | the building: zones with their closing times, rooms with their rules, teams, team grants |
| `staff.json` | the people: employees with their teams, badges, certifications and bans; contractors; visitors and their escorts |
| `load.py` | loads both files into an empty database |
| `controller.py` | `DoorController`: the decision, the log and the positions, one query per swipe |
| `monitor.py` | the checks, the alarms, and `serve`, the monitor's process |
| `day.py` | the day as data: each badge's itinerary, and the site operations |
| `simulate.py` | runs the day and prints what happened |

## Loading the site

The files are plain JSON: names, numbers, and times and dates as ISO 8601 text. Each kind of thing
is one query over a list parameter, so the load is a dozen transactions however many people the
files hold. The rooms, for example:

```{literalinclude} ../../examples/helix/load.py
:language: python
:start-at: "# Rooms, each with its door"
:dedent: 4
:end-before: "UNWIND $site.rooms AS room WITH room WHERE room.high_containment"
```

`SET` with a missing value (`room.min_occupancy` for a room without one) sets nothing, so one
query serves rooms with and without each rule. Times and dates become temporal values inside the
queries: `localtime(grant.from)`, `date(c.valid_until)`.

## The door controller

The decision is the one built in [step 18](../tutorial/18-door-controller), with one change: it
says **why** a swipe was refused. Each rule is a column, and `refusal` names the first one broken.
The team grants are gathered once, as a list, so the same list answers both "may they ever enter
this zone?" and "may they enter it now?". That is what separates *no access* from *outside hours*.

```{literalinclude} ../../examples/helix/controller.py
:language: python
:start-at: "ENTER = "
:end-before: "# A refused swipe ends ENTER"
```

The refusal is stored on the swipe, so the security office can count refusals by reason (the
"refused" line at the end of the output). The query creates the swipe for every row, and only
continues to the writes that move the person when the door opens. A refused swipe therefore ends
the query with no rows, and `DoorController.enter` then reads the reason back from the log.

## The monitor, in its own process

The checks are those of [step 19](../tutorial/19-monitoring). `check(db, at)` runs them and
returns what changed: the alarms raised in this run, and the ones cleared. `serve` is the
monitor's process. It opens the database itself and runs a check for each time it receives:

```{literalinclude} ../../examples/helix/monitor.py
:language: python
:pyobject: serve
```

The simulation starts it with `multiprocessing` (`spawn`, so the child shares no state with the
parent) and sends it the simulated time:

```{mermaid}
sequenceDiagram
  participant R as readers (main process)
  participant D as database directory
  participant M as monitor (second process)
  R->>D: ENTER / LEAVE, one transaction per swipe
  R->>M: check at 12:40
  M->>D: the six checks (read)
  M->>D: RAISE / CLEAR (write)
  M-->>R: report: raised alone, cleared overstay
  R->>D: ENTER / LEAVE …
```

The controllers' writes and the monitor's take turns: LMDB lets one write transaction run at a
time, across processes. The monitor's reads see a consistent snapshot, never half of a swipe. In
production the two would run independently on the clock. Here the readers wait for each check, so
every run prints the same day.

The database is opened with `durability="deferred"`, because a simulation does not need each
commit on disk before going on. A real controller would keep the default, `"full"`.

## The day

`day.py` gives each badge an itinerary: the times its holder goes into a room, and when they go
home. The doors may refuse; a refused person stays where they were and goes on with their day.
Comments mark the moments that test a rule:

```{literalinclude} ../../examples/helix/day.py
:language: python
:start-at: "# Virology"
:dedent: 4
:end-before: "# Biosafety"
```

Reading the output against it:

- **08:30** Kemi has no BSL-3 certification: *training missing*.
- **10:10** Dalia, Joon, Nadia and Luca are in the BSL-3 lab, which takes four: Sara and Yusuf
  are refused, *room full*, and come back in the afternoon.
- **12:35** Dalia and Joon have been inside since 08:30: *overstay*.
- **12:40** they come out, which clears the overstay, and leaves Nadia alone: *alone*. Nothing
  at the door can prevent this, because a door always lets people out.
- **18:00** the suite closes with Sara and Yusuf inside: *after closing*. Ten minutes later they
  pass four hours too: *overstay*.

The other teams' days test the remaining rules:

- Emeka arrives before the genomics floor opens: *outside hours*.
- Lars, on the night shift, is not trained for the animal rooms.
- The head of research manages the research teams, which reaches every zone they may enter,
  but a ban on the containment suite overrides that.
- Ada leaves her visitor alone in the seminar room.
- Fatima and Olga leave the vivarium control room empty for half an hour.
- The facilities team lowers the sequencing lab's limit with five people inside.

## Exploring the result

With `--database`, the day stays on disk to be queried:

```python
# docs-test: skip
import acmedb

with acmedb.Database("helix-day") as db:
    print(db.query("""
        MATCH (s:Swipe)-[:BY]->(:Badge)-[:ISSUED_TO]->(p:Person {name: 'Nadia Petrova'}),
              (s)-[:AT]->(d:Door)
        RETURN s.at, d.id, s.direction, s.refusal ORDER BY s.at
    """))
```

Things to try:

- change an itinerary in `day.py`, or a rule in `site.json`, and run the day again;
- set the BSL-3 lab's `min_occupancy` to 1 and watch the *alone* alarm disappear;
- add the Sequencing Lab to Hiro Tanaka's rooms in `staff.json`, and the 10:40 refusal becomes the
  lab's to decide by its occupancy.
