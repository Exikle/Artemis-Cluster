import json
import os
import subprocess
import sys

sys.path.insert(0, "/opt/hermes")
import hermes_yaml  # noqa: E402

HOME = os.environ.get("HERMES_HOME", "/opt/data")
JOBS_FILE = os.path.join(HOME, "cron", "jobs.json")
HERMES = os.environ.get("HERMES_BIN", "hermes")
MANAGED = ("schedule", "skills", "script", "model", "deliver")


def log(msg):
    print(f"cron-reconcile: {msg}", flush=True)


def load_spec(path):
    try:
        with open(path, encoding="utf-8") as fh:
            spec = hermes_yaml.safe_load(fh.read())
    except Exception as exc:
        log(f"FATAL cannot parse {path}: {exc}")
        sys.exit(2)
    if not isinstance(spec, dict) or not isinstance(spec.get("jobs"), list):
        log(f"FATAL {path} must be a mapping with a 'jobs' list")
        sys.exit(2)
    return spec["jobs"]


def load_current():
    try:
        with open(JOBS_FILE, encoding="utf-8") as fh:
            jobs = json.load(fh).get("jobs", [])
    except FileNotFoundError:
        return {}
    by_name = {}
    for job in jobs:
        by_name.setdefault(job.get("name"), []).append(job)
    return by_name


def run(args):
    proc = subprocess.run([HERMES, "cron", *args], capture_output=True, text=True)
    out = (proc.stdout + proc.stderr).strip().replace("\n", " | ")
    return proc.returncode == 0, out


def current_value(job, key):
    if key == "schedule":
        sched = job.get("schedule") or {}
        return sched.get("expr") or job.get("schedule_display")
    if key == "skills":
        return list(job.get("skills") or ([job["skill"]] if job.get("skill") else []))
    return job.get(key) or None


def desired_value(want, key):
    if key == "skills":
        return list(want.get("skills") or [])
    return want.get(key) or None


def validate(want):
    if not isinstance(want, dict) or not isinstance(want.get("name"), str) or not want["name"]:
        return "entry has no name"
    if not isinstance(want.get("schedule"), str) or not want["schedule"]:
        return "no schedule"
    if "skills" in want and not isinstance(want["skills"], list):
        return "skills must be a list"
    return None


def create_args(want):
    args = ["create", want["schedule"], "--name", want["name"]]
    for skill in want.get("skills") or []:
        args += ["--skill", skill]
    for key in ("script", "model", "deliver"):
        if want.get(key):
            args += [f"--{key}", want[key]]
    if not want.get("enabled", True):
        args += ["--paused"]
    return args


def edit_args(job, want):
    args = ["edit", job["id"]]
    for key in MANAGED:
        if key not in want:
            continue
        have, wanted = current_value(job, key), desired_value(want, key)
        if have == wanted:
            continue
        if key == "schedule":
            args += ["--schedule", wanted]
        elif key == "skills":
            for skill in wanted:
                args += ["--skill", skill]
            if not wanted:
                args += ["--clear-skills"]
        else:
            args += [f"--{key}", wanted or ""]
    return args if len(args) > 2 else None


def reconcile_job(want, current):
    name = want["name"]
    matches = current.get(name, [])
    if len(matches) > 1:
        log(f"ERROR {name}: {len(matches)} jobs share this name, skipped")
        return False
    if not matches:
        ok, out = run(create_args(want))
        log(f"{'created' if ok else 'ERROR create failed'} {name}: {out}")
        return ok
    job = matches[0]
    ok = True
    args = edit_args(job, want)
    if args:
        ok, out = run(args)
        log(f"{'edited' if ok else 'ERROR edit failed'} {name} ({job['id']}): {' '.join(args[2:])} -> {out}")
    else:
        log(f"matched {name} ({job['id']}): nothing to change")
    enabled = bool(want.get("enabled", True))
    if enabled != bool(job.get("enabled", True)):
        ok2, out = run(["resume" if enabled else "pause", job["id"]])
        log(f"{'resumed' if enabled else 'paused'} {name}: {out}" if ok2 else f"ERROR state change failed {name}: {out}")
        ok = ok and ok2
    return ok


def main():
    wanted = load_spec(sys.argv[1])
    current = load_current()
    declared = set()
    errors = 0
    for want in wanted:
        problem = validate(want)
        if problem:
            log(f"ERROR {want!r}: {problem}")
            errors += 1
            continue
        declared.add(want["name"])
        try:
            if not reconcile_job(want, current):
                errors += 1
        except Exception as exc:
            log(f"ERROR {want['name']}: {exc}")
            errors += 1
    for name, jobs in current.items():
        if name not in declared:
            for job in jobs:
                log(f"unmanaged job left untouched: {name} ({job.get('id')})")
    log(f"done: {len(declared)} declared, {errors} errors")


main()
