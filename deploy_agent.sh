#!/bin/bash
#
# deploy_agent.sh
# Bootstraps, runs and archives the Student Attendance Tracker.
#
# Features:
#   1. deploy  - create attendance_tracker_<name>/ from the templates
#   2. run     - launch attendance_checker.py inside a deployed project
#   3. archive - copy reports/*.log into timestamped archive folders
#
# Ctrl+C / Ctrl+Z are trapped while a deployment is in progress. The half
# built project gets zipped and removed so nothing broken is left behind.
#
# Author: vbigwi

# always work relative to where this script lives so the templates/ folder
# and the deployed projects end up in a predictable place
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
cd "$SCRIPT_DIR" || exit 1

PROJECT_NAME=""   # what the user typed
PROJECT_DIR=""    # attendance_tracker_<PROJECT_NAME>
DEPLOY_IN_PROGRESS=0

# sample data used when the user wants a freshly generated roster (option B)
SAMPLE_NAMES=(
    "Amina Uwase" "Brian Okafor" "Chantal Mukamana" "David Nkurunziza"
    "Esther Achieng" "Frank Mugisha" "Grace Ingabire" "Henry Kamau"
    "Irene Nyirahabimana" "Jean Habimana" "Kevin Otieno" "Linda Abebe"
    "Moses Tumusiime" "Nadia Keza" "Oscar Byiringiro"
)
SAMPLE_EMAILS=(
    "amina@example.com" "brian@example.com" "chantal@example.com"
    "david@example.com" "esther@example.com" "frank@example.com"
    "grace@example.com" "henry@example.com" "irene@example.com"
    "jean@example.com" "kevin@example.com" "linda@example.com"
    "moses@example.com" "nadia@example.com" "oscar@example.com"
)

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
warn()  { echo "[WARN]  $*"; }
error() { echo "[ERROR] $*" >&2; }

# read one line into the variable named by $2. If stdin is closed (Ctrl+D or
# an exhausted pipe) there is no point asking the same question forever, so
# bail out with a clear message instead.
prompt() {
    local __text="$1" __var="$2"
    if ! read -r -p "$__text" "$__var"; then
        echo
        error "input closed before the question was answered, aborting."
        exit 1
    fi
}

# true when $1 is a whole number (no sign, no decimals, not empty)
is_number() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# keep asking until the answer is y or n
ask_yes_no() {
    local question="$1" answer
    while true; do
        prompt "$question [y/n]: " answer
        case "$answer" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO)   return 1 ;;
            *) echo "  please answer y or n" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# signal handling (only active while deploying)
# ---------------------------------------------------------------------------

on_interrupt() {
    echo
    echo "=================================================="
    echo " Deployment interrupted! (Ctrl+C / Ctrl+Z received)"
    echo "=================================================="

    if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
        local zip_name="${PROJECT_DIR}_archive.zip"
        info "zipping what was created so far -> $zip_name"
        rm -f "$zip_name"
        if zip -r -q "$zip_name" "$PROJECT_DIR"; then
            ok "archive saved: $SCRIPT_DIR/$zip_name"
        else
            error "zip failed, leaving $PROJECT_DIR in place so nothing is lost"
            exit 130
        fi
        # don't leave a half made project lying around
        rm -rf "$PROJECT_DIR"
        ok "removed incomplete directory $PROJECT_DIR"
    else
        info "nothing was created yet, nothing to archive"
    fi

    echo "Closing session."
    exit 130
}

enable_trap() {
    DEPLOY_IN_PROGRESS=1
    trap on_interrupt SIGINT SIGTSTP
}

disable_trap() {
    DEPLOY_IN_PROGRESS=0
    trap - SIGINT SIGTSTP
}

# ---------------------------------------------------------------------------
# feature 1: deploy
# ---------------------------------------------------------------------------

preflight_checks() {
    info "running pre-flight checks..."
    local missing=0

    if command -v python3 >/dev/null 2>&1; then
        ok "python3 found: $(python3 --version 2>&1)"
    else
        error "python3 is not installed. Install it with: sudo apt install python3"
        missing=1
    fi

    if command -v zip >/dev/null 2>&1; then
        ok "zip found: $(zip -v 2>/dev/null | head -n 2 | tail -n 1 | awk '{print $1, $2, $3, $4}')"
    else
        error "zip is not installed. Install it with: sudo apt install zip"
        missing=1
    fi

    # the templates folder is just as important, no point going on without it
    for f in attendance_checker.py assets.csv config.json; do
        if [ ! -f "$TEMPLATES_DIR/$f" ]; then
            error "template missing: $TEMPLATES_DIR/$f"
            missing=1
        fi
    done

    if [ "$missing" -ne 0 ]; then
        error "pre-flight checks failed, aborting."
        exit 1
    fi
    ok "pre-flight checks passed"
}

ask_project_name() {
    local name
    while true; do
        prompt "Enter a name for the project (attendance_tracker_<name>): " name
        if [ -z "$name" ]; then
            echo "  name cannot be empty"
        elif [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
            echo "  only letters, numbers, _ and - are allowed"
        else
            break
        fi
    done
    PROJECT_NAME="$name"
    PROJECT_DIR="attendance_tracker_${PROJECT_NAME}"
}

create_structure() {
    if [ -d "$PROJECT_DIR" ]; then
        warn "$PROJECT_DIR already exists."
        if ask_yes_no "Overwrite it? (everything inside will be deleted)"; then
            rm -rf "$PROJECT_DIR" || { error "could not remove $PROJECT_DIR"; exit 1; }
            info "old $PROJECT_DIR removed"
        else
            error "aborting, existing project left untouched."
            exit 1
        fi
    fi

    if ! mkdir -p "$PROJECT_DIR/Helpers" "$PROJECT_DIR/reports"; then
        error "could not create $PROJECT_DIR (permission denied?)"
        exit 1
    fi
    ok "created $PROJECT_DIR/ with Helpers/ and reports/"
}

# option A - take the first N students from the template roster
copy_roster_from_template() {
    local template="$TEMPLATES_DIR/assets.csv"
    local available count
    available=$(( $(wc -l < "$template") - 1 ))   # minus the header

    while true; do
        prompt "How many students to copy from the template (1-$available)? " count
        if ! is_number "$count"; then
            echo "  please enter a whole number"
        elif [ "$count" -lt 1 ] || [ "$count" -gt "$available" ]; then
            echo "  the template only has $available students"
        else
            break
        fi
    done

    # header + N rows
    head -n $(( count + 1 )) "$template" > "$PROJECT_DIR/Helpers/assets.csv"
    ok "copied $count students from the template roster"

    # template students already have 4 sessions recorded so today is the 5th
    set_total_sessions 5
}

# option B - build a brand new roster from the sample arrays
generate_fresh_roster() {
    local max=${#SAMPLE_NAMES[@]} count i

    while true; do
        prompt "How many students to generate (1-$max)? " count
        if ! is_number "$count"; then
            echo "  please enter a whole number"
        elif [ "$count" -lt 1 ] || [ "$count" -gt "$max" ]; then
            echo "  I only have $max sample students"
        else
            break
        fi
    done

    {
        echo "Email,Names,Attendance Count,Absence Count"
        for (( i = 0; i < count; i++ )); do
            echo "${SAMPLE_EMAILS[$i]},${SAMPLE_NAMES[$i]},0,0"
        done
    } > "$PROJECT_DIR/Helpers/assets.csv"
    ok "generated a fresh roster with $count students (all counts at 0)"

    # nobody has any history yet so this run is session number 1
    set_total_sessions 1
}

# total_sessions must always be (prior sessions in the roster) + 1 otherwise
# the python app complains about every student
set_total_sessions() {
    local value="$1"
    sed -i "s/\"total_sessions\": [0-9]*/\"total_sessions\": $value/" "$PROJECT_DIR/Helpers/config.json"
    ok "config.json total_sessions set to $value"
}

populate_files() {
    cp "$TEMPLATES_DIR/attendance_checker.py" "$PROJECT_DIR/attendance_checker.py" || exit 1
    cp "$TEMPLATES_DIR/config.json" "$PROJECT_DIR/Helpers/config.json" || exit 1
    ok "copied attendance_checker.py and config.json from templates/"

    echo
    echo "How should the roster (Helpers/assets.csv) be built?"
    echo "  A) copy students from templates/assets.csv"
    echo "  B) generate a fresh roster with new students"
    local choice
    while true; do
        prompt "Choose A or B: " choice
        case "$choice" in
            a|A) copy_roster_from_template; break ;;
            b|B) generate_fresh_roster; break ;;
            *) echo "  please type A or B" ;;
        esac
    done
}

set_permissions() {
    chmod +x "$PROJECT_DIR/attendance_checker.py" || { error "chmod +x failed"; exit 1; }
    chmod 600 "$PROJECT_DIR/Helpers/config.json" || { error "chmod 600 failed"; exit 1; }

    echo
    info "permissions set:"
    echo "  $(stat -c '%A' "$PROJECT_DIR/attendance_checker.py")  attendance_checker.py  (executable)"
    echo "  $(stat -c '%A' "$PROJECT_DIR/Helpers/config.json")  Helpers/config.json    (owner read/write only)"
}

# reads one threshold into the variable named by $3, keeps the default when
# the user just presses enter
read_threshold() {
    local label="$1" default="$2" __out="$3" value
    while true; do
        prompt "  $label threshold [$default]: " value
        value="${value:-$default}"
        if ! is_number "$value"; then
            echo "  '$value' is not a number, try again"
        elif [ "$value" -gt 100 ]; then
            echo "  it is a percentage, must be between 0 and 100"
        else
            printf -v "$__out" '%s' "$value"
            return
        fi
    done
}

update_thresholds() {
    local config="$PROJECT_DIR/Helpers/config.json"
    local warning failure

    echo
    if ! ask_yes_no "Do you want to update the attendance alert thresholds?"; then
        info "keeping default thresholds (warning 75, failure 50)"
        return
    fi

    while true; do
        read_threshold "warning" 75 warning
        read_threshold "failure" 50 failure
        if [ "$failure" -ge "$warning" ]; then
            echo "  failure ($failure) should be lower than warning ($warning), try again"
        else
            break
        fi
    done

    # only touch the two threshold lines, leave the rest of the file as is
    sed -i "s/\"warning\": [0-9]*/\"warning\": $warning/" "$config"
    sed -i "s/\"failure\": [0-9]*/\"failure\": $failure/" "$config"

    ok "thresholds updated in Helpers/config.json:"
    grep -E '"(warning|failure)"' "$config"
}

deploy() {
    echo
    echo "=== Feature 1: Deploy the application ==="
    preflight_checks
    echo

    # from here on a Ctrl+C / Ctrl+Z zips and removes the partial project
    enable_trap

    ask_project_name
    create_structure
    populate_files
    set_permissions
    update_thresholds

    disable_trap   # the python app handles its own Ctrl+C from here

    echo
    ok "deployment of $PROJECT_DIR complete"
    echo
    echo "Structure:"
    find "$PROJECT_DIR" | sort | sed 's/^/  /'

    echo
    info "verifying the deployment by launching the application..."
    run_app "$PROJECT_NAME"
}

# ---------------------------------------------------------------------------
# feature 2: run
# ---------------------------------------------------------------------------

run_app() {
    local name="$1" dir
    [ -z "$name" ] && prompt "Project name to run (attendance_tracker_<name>): " name
    dir="attendance_tracker_${name}"

    if [ ! -d "$dir" ]; then
        error "$dir does not exist. Deploy it first."
        return 1
    fi
    if [ ! -f "$dir/attendance_checker.py" ]; then
        error "$dir/attendance_checker.py is missing, this project looks broken."
        return 1
    fi

    echo
    echo "=== Feature 2: Run the application ($dir) ==="
    echo "Handing the terminal over to attendance_checker.py..."
    echo
    (
        cd "$dir" || exit 1
        python3 attendance_checker.py
    )
    local status=$?
    echo
    if [ "$status" -eq 0 ]; then
        ok "attendance_checker.py finished successfully"
        info "you can archive the logs with: ./deploy_agent.sh archive $name"
    else
        warn "attendance_checker.py exited with status $status"
    fi
    return "$status"
}

# ---------------------------------------------------------------------------
# feature 3: archive
# ---------------------------------------------------------------------------

archive_logs() {
    local name="$1" dir stamp log archived=0
    [ -z "$name" ] && prompt "Project name to archive (attendance_tracker_<name>): " name
    dir="attendance_tracker_${name}"

    if [ ! -d "$dir" ]; then
        error "$dir does not exist. Nothing to archive."
        return 1
    fi

    echo
    echo "=== Feature 3: Archive the log files ($dir) ==="

    # one timestamp for the whole run so both logs match up
    stamp=$(date +%Y%m%d_%H%M%S)

    for log in attendance absent; do
        local src="$dir/reports/$log.log"
        local dest_dir="$dir/archives/$log"
        local dest="$dest_dir/${log}_${stamp}.log"

        if [ ! -f "$src" ]; then
            warn "$src not found, skipping (no $log entries were written)"
            continue
        fi

        mkdir -p "$dest_dir" || { error "could not create $dest_dir"; continue; }
        if cp "$src" "$dest"; then
            ok "archived $log.log -> $dest"
            archived=$(( archived + 1 ))
        else
            error "failed to copy $src"
        fi
    done

    if [ "$archived" -eq 0 ]; then
        warn "no logs were archived. Run the application first to generate them."
    else
        info "$archived log file(s) archived under $dir/archives/"
    fi
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------

usage() {
    cat <<USAGE
Usage: $0 [deploy | run <name> | archive <name>]

  deploy          create a new attendance_tracker_<name> project
  run <name>      start attendance_checker.py inside attendance_tracker_<name>
  archive <name>  archive reports/*.log of attendance_tracker_<name>

Without arguments an interactive menu is shown.
USAGE
}

show_menu() {
    while true; do
        echo
        echo "======== Attendance Tracker deploy agent ========"
        echo "  1) Deploy the application"
        echo "  2) Run the application"
        echo "  3) Archive the log files"
        echo "  4) Quit"
        prompt "Choose an option [1-4]: " choice
        case "$choice" in
            1) deploy ;;
            2) run_app "" ;;
            3) archive_logs "" ;;
            4) echo "Bye."; exit 0 ;;
            *) echo "  invalid option, pick 1-4" ;;
        esac
    done
}

case "${1:-}" in
    "")                 show_menu ;;
    deploy|--deploy)    deploy ;;
    run|--run)          run_app "${2:-}" ;;
    archive|--archive)  archive_logs "${2:-}" ;;
    -h|--help|help)     usage ;;
    *) error "unknown option: $1"; usage; exit 1 ;;
esac
