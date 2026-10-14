# deploy_agent_vbigwi

Shell script that bootstraps, runs and archives the **Student Attendance Tracker**
(`attendance_checker.py`). The Python app is not modified, everything here is the
shell automation around it.

```
deploy_agent_vbigwi/
├── deploy_agent.sh          # the script
├── templates/
│   ├── attendance_checker.py
│   ├── assets.csv
│   └── config.json
└── README.md
```

## Requirements

- bash
- `python3`
- `zip` (used by the interrupt handler)

The script checks for `python3` and `zip` before deploying and stops with a clear
message if one of them is missing.

## Running the script and choosing a feature

```bash
chmod +x deploy_agent.sh
./deploy_agent.sh
```

With no arguments you get a small menu:

```
======== Attendance Tracker deploy agent ========
  1) Deploy the application
  2) Run the application
  3) Archive the log files
  4) Quit
Choose an option [1-4]:
```

I also added command line flags so a feature can be run directly, which is
handier when you already know the project name:

```bash
./deploy_agent.sh deploy            # feature 1
./deploy_agent.sh run <name>        # feature 2  -> attendance_tracker_<name>
./deploy_agent.sh archive <name>    # feature 3
./deploy_agent.sh --help
```

I went with the menu as the default because the deploy step is already a
conversation (name, roster choice, thresholds...), so a menu felt consistent.
The flags are there for people who prefer typing.

## Feature 1: deploy

1. **Pre-flight checks** – `python3` and `zip` must be installed (the script
   prints their versions), and the three template files must exist in
   `templates/`.
2. **Project name** – you are asked for a name and the script creates
   `attendance_tracker_<name>/`. Only letters, numbers, `_` and `-` are accepted.
   If the directory already exists you are asked whether to overwrite it. If you
   say no the script aborts and leaves the existing project untouched.
3. **Structure and files**

   ```
   attendance_tracker_<name>/
   ├── attendance_checker.py     (copied unmodified from templates/)
   ├── Helpers/
   │   ├── assets.csv            (built, see below)
   │   └── config.json           (copied from templates/, then adjusted)
   └── reports/                  (empty, the app writes its logs here)
   ```

   The roster `Helpers/assets.csv` can be built in two ways:

   - **Option A – copy from the template.** You choose how many students (1 to
     10) and the script copies the header plus that many rows from
     `templates/assets.csv` with `head`.
   - **Option B – generate a fresh roster.** You choose how many students (1 to
     15) and the script builds the rows from two arrays of sample names and
     emails defined at the top of the script. Attendance Count and Absence
     Count start at 0.

   The count is validated: it must be a whole number inside the allowed range,
   otherwise you are asked again.

4. **`total_sessions`** – `attendance_checker.py` expects
   `total_sessions = prior sessions on record + 1`. The template students
   already have 4 sessions recorded (Attendance Count + Absence Count = 4), so
   option A keeps `total_sessions: 5`. A fresh roster has no history, so for
   option B the script sets `total_sessions: 1`. This is done with `sed` on the
   deployed `config.json`, there is no prompt for it.
5. **Permissions** – `attendance_checker.py` gets `chmod +x` and
   `Helpers/config.json` gets `chmod 600` (owner read/write only, since it
   holds the grading thresholds). The script prints the resulting modes.
6. **Threshold update** – see next section.
7. **Verification** – the deploy ends by launching the app (feature 2). If it
   starts and lists the students, the structure, roster and config are all
   consistent.

## How the threshold update works

After the permissions step the script asks:

```
Do you want to update the attendance alert thresholds? [y/n]:
```

If you answer `y` it asks for the two values with `read`, showing the defaults
in brackets. Pressing Enter keeps the default:

```
  warning threshold [75]: 80
  failure threshold [50]: 60
```

Validation before anything is written:

- the value must be a whole number (`abc`, `7.5` or an empty answer that is not
  the default are rejected and asked again),
- it must be between 0 and 100 because it is a percentage,
- `failure` must be lower than `warning`, otherwise the pair is asked again.

Only then the deployed `Helpers/config.json` is edited in place with `sed`:

```bash
sed -i "s/\"warning\": [0-9]*/\"warning\": $warning/" "$config"
sed -i "s/\"failure\": [0-9]*/\"failure\": $failure/" "$config"
```

The patterns target exactly the `"warning": <number>` and
`"failure": <number>` lines, so the indentation, order and the other keys in the
file stay as they are. The script prints the two updated lines afterwards so you
can see the result.

## Feature 2: run

```bash
./deploy_agent.sh run <name>
```

Checks that `attendance_tracker_<name>/` and its `attendance_checker.py` exist,
then does `cd attendance_tracker_<name> && python3 attendance_checker.py`. The
app is interactive and takes over the terminal to mark each student. When it is
done the script prints the exit status and reminds you about the archive command.

## Feature 3: archive (how the log archiving works)

```bash
./deploy_agent.sh archive <name>
```

The app writes `reports/attendance.log` and, only when at least one student was
absent, `reports/absent.log`. The archive feature:

1. takes one timestamp with `date +%Y%m%d_%H%M%S` so both copies of the same run
   share it,
2. for each log that exists, creates its own directory and copies the log into it
   with the timestamp in the file name,
3. prints what was archived and where, and a warning for a log that does not
   exist (for example no `absent.log` when everyone was present). A missing log
   is reported, it does not stop the script.

```
attendance_tracker_<name>/
└── archives/
    ├── attendance/
    │   └── attendance_20261014_024557.log
    └── absent/
        └── absent_20261014_024557.log
```

Because the name carries the timestamp every archived copy is unique, and you can
run the archive feature after every marking session without overwriting earlier
copies. The archive is triggered manually (menu option 3 or the `archive` flag)
after a run, not automatically, so the instructor decides when a session is
"closed".

## Signal handling: Ctrl+C and Ctrl+Z during deploy

While feature 1 is running the script traps `SIGINT` (Ctrl+C) and `SIGTSTP`
(Ctrl+Z):

```bash
trap on_interrupt SIGINT SIGTSTP
```

The trap is enabled right before the project name prompt and removed again just
before the app is launched, because `attendance_checker.py` handles its own
Ctrl+C during a marking session. On a signal the handler:

1. prints a message saying the deployment was interrupted,
2. zips whatever exists of `attendance_tracker_<name>/` into
   `attendance_tracker_<name>_archive.zip` with `zip -r`,
3. deletes the incomplete `attendance_tracker_<name>/` so no half-made project is
   left in the workspace,
4. exits with status 130.

If nothing was created yet (interrupted at the name prompt) it just says so and
exits. If `zip` fails the directory is kept so nothing is lost.

### How to test it

```bash
./deploy_agent.sh deploy
# enter a name, pick a roster option, then press Ctrl+C (or Ctrl+Z)
# at the thresholds question
```

You should see the interrupted message, then:

```bash
ls                                           # no attendance_tracker_<name>/ any more
unzip -l attendance_tracker_<name>_archive.zip
```

The zip contains the state at the moment of the interrupt, for example:

```
attendance_tracker_test/
attendance_tracker_test/Helpers/
attendance_tracker_test/Helpers/config.json
attendance_tracker_test/Helpers/assets.csv
attendance_tracker_test/reports/
attendance_tracker_test/attendance_checker.py
```

If you interrupt earlier (at the roster question) the zip has no `assets.csv`
yet, which is a nice way to confirm it really captures the partial state.

I also tested it without pressing keys, by sending the signals from a second
terminal:

```bash
kill -INT  $(pgrep -f deploy_agent.sh)
kill -TSTP $(pgrep -f deploy_agent.sh)
```

## How I tested the deployed structure

- Deployed with option A (5 students) and option B (3 students), then checked
  with `find attendance_tracker_<name> -type f` and `cat` that the tree matches
  the required layout, that `assets.csv` has the right number of rows and that
  `config.json` has `total_sessions` 5 or 1 respectively.
- Verified permissions with `ls -l`: `-rwxr-xr-x` on `attendance_checker.py` and
  `-rw-------` on `Helpers/config.json`.
- Ran a full marking session right after deploying (this is what the deploy step
  does automatically) and confirmed `reports/attendance.log` and
  `reports/absent.log` were created and the counts in `assets.csv` went up.
- Fed wrong input on purpose: letters and out-of-range numbers for the student
  count, `xyz`, `150` and a failure value higher than warning for the thresholds.
  All were rejected and asked again, nothing was written to `config.json` until
  the values were valid.
- Deployed the same name twice: answering `n` aborts and keeps the old project,
  answering `y` replaces it.
- Ran the archive feature on a project where nobody was absent to check the
  missing `absent.log` is reported and not treated as an error, and on a project
  name that does not exist.
- Closed stdin (Ctrl+D) at a prompt to make sure the script stops instead of
  looping on the question.

## Notes

- `attendance_tracker_*/` and the interrupt zips are in `.gitignore` so test
  deployments never end up in the repo.
- The script always works relative to its own directory, so it can be called
  from anywhere and still find `templates/`.
