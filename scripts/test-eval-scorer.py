#!/usr/bin/env python3
"""Unit tests for eval-instructions.py's scorer. Offline, free, runs in lefthook.

The scorer's hard case is negation: a correct answer usually has to NAME the forbidden thing to
rule it out ("SOPS is fully removed", "no `git add .`"). Naive substring matching scored all of
those as failures and made a correct instruction set look broken. These tests pin both directions
— a negated mention must pass, an affirmative one must still fail — because a scorer that never
fires is indistinguishable from a repo with no problems.
"""
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ev", str(__import__("pathlib").Path(__file__).resolve().parent / "eval-instructions.py"))
ev = importlib.util.module_from_spec(spec); spec.loader.exec_module(ev)
T = [
 ("negated-before: git add .", {"forbidden":["git add .","git add -A"]},
  "`git add <f1> <f2>`\n\nStage by name only — no `git add .` or `git add -A`.", True),
 ("negated-before: co-authored-by", {"forbidden":["co-authored-by"]},
  "One-line subject with no body and no `Co-Authored-By` trailer.", True),
 ("negated-after: sops removed", {"forbidden":["sops"]},
  "Secrets are exclusively 1Password + ExternalSecrets. SOPS and age are fully removed.", True),
 ("negated-after: ceph gone", {"forbidden":["ceph-block"]},
  "ceph-block no longer exists in this cluster.", True),
 ("AFFIRM: sops encrypt", {"forbidden":["sops"]},
  "Encrypt the file with sops --encrypt and commit it.", False),
 ("AFFIRM: git add .", {"forbidden":["git add ."]},
  "Just run git add . and then commit.", False),
 ("AFFIRM: ceph-block", {"forbidden":["ceph-block"]},
  "Set storageClassName: ceph-block on the PVC.", False),
 ("AFFIRM across sentence boundary", {"forbidden":["ceph-block"]},
  "Use ceph-block here. Rook-Ceph was removed last year.", False),
 ("required still works", {"required":["miroir"]}, "Use storageClassName: miroir.", True),
 ("required missing", {"required":["miroir"]}, "Use whatever default.", False),
 ("any_of hit", {"any_of":["shared","postgres-rw"]}, "Onboard onto the shared cluster.", True),
 ("any_of miss", {"any_of":["shared","postgres-rw"]}, "Create a new CNPG Cluster.", False),
]
bad=0
for label, case, reply, want in T:
    ok,_ = ev.score(case, reply)
    if ok!=want: bad+=1
    print(f"  {'ok ' if ok==want else 'BAD'} {label:<36} pass={ok} want={want}")

MAJORITY = [
 ("1 run, pass",            [True],                       True),
 ("1 run, fail",            [False],                      False),
 ("3 runs, 3 pass",         [True,True,True],             True),
 ("3 runs, 2 pass",         [True,True,False],            True),
 ("3 runs, 1 pass (noise)", [True,False,False],           False),
 ("2 runs, even split",     [True,False],                 False),
 ("4 runs, even split",     [True,True,False,False],      False),
 ("5 runs, 3 pass",         [True,True,True,False,False], True),
]
for label, votes, want in MAJORITY:
    got = ev.majority(votes)
    if got != want: bad += 1
    print(f"  {'ok ' if got==want else 'BAD'} majority: {label:<24} {sum(votes)}/{len(votes)} -> {got}")

print("\nall scorer unit tests pass" if not bad else f"\n{bad} FAILED")
sys.exit(1 if bad else 0)
