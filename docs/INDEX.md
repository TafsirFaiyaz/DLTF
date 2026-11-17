# DLTF Documentation Index

Eleven documents, all current as of the latest verified run. Start with §1 if
you are setting up, §2 if you are writing.

---

## 1. Getting the system running

| Document | Read it when |
|---|---|
| **`SETUP_GUIDE.md`** | first install, or something broke |
| **`FOLDER_STRUCTURE.md`** | placing files, deciding what to delete |
| **`requirements.txt`** / **`requirements-chain.txt`** | `pip install -r` |

`SETUP_GUIDE.md` has 12 sections in the order things actually break: system
packages, venv (with the NumPy ABI trap), Python deps, Solidity toolchain (with
the solc pin evidence), install verification, SIM, evaluation, Tailscale, TPM
certs, REAL mode, live node, troubleshooting table.

`FOLDER_STRUCTURE.md` is the full tree with every file tagged NEW / REPLACE /
yours / ⚠, install commands, and nine decisions you still owe.

## 2. Writing the thesis

| Document | Read it when |
|---|---|
| **`THESIS_CONTEXT.md`** | **start here — writing any chapter** |
| **`HOW_THE_BLOCKCHAIN_WORKS.md`** | writing Ch. 3 §chain or Ch. 5 |
| **`MASTER_CONTEXT.md`** | you need the authoritative system state |
| **`RESULTS_EXPLAINED.md`** | writing Ch. 4 or Ch. 5 numbers |
| **`GRAPHS_AND_VERIFICATION.md`** | choosing and regenerating figures |

`THESIS_CONTEXT.md` opens with **§0: eight claims you must not make**, each with
the defensible rephrasing. Then the problem statement, threat model,
architecture, the full reputation engine with constant provenance, chain layer,
measured results, limitations, related-work positioning, and a chapter plan.

`HOW_THE_BLOCKCHAIN_WORKS.md` answers "does the client send a txid?" (no, and
why that's deliberate), with a live 24-event trace and the semantic-vs-state API
argument.

`MASTER_CONTEXT.md` is the rewritten version — the one in your repo described
the **v2.1** engine whose constants no longer exist in the code.

## 3. Running and verifying

| Document | Read it when |
|---|---|
| **`TEST_COMMANDS.md`** | **the master catalogue — 8 tiers** |
| **`FORGE_LINT_WARNINGS.md`** | `forge build` printed unsafe-typecast notes |
| **`TIER_0_6_VERIFICATION.md`** | checking your latest run |
| **`SIM_WALKTHROUGH.md`** | demoing on one PC |
| **`REAL_MODE_RUNBOOK.md`** | the three-machine deployment |

`TEST_COMMANDS.md` gives every command with what it tests, expected output, what
it means, and what to do on failure. Plus a `run_all_tests.sh` one-shot script.

`REAL_MODE_RUNBOOK.md` opens with the finding that **two physical clients cannot
demonstrate detection** — read §0 before attempting the live attack demo.

---

## Code delivered

```
chain/reconcile.py          rebuild ReputationEngine from chain (N23)
chain/wiring.py             --chain flag -> audit object, + require_commit
chain/evm.py                live-node backend, layout-agnostic artifacts
chain/deploy.py             deploy + deployed.json
chain/verifier.py           REPLACE - knows non-state commitment events
chain/evm_parity_test.py    REPLACE - layout-agnostic, correct build command
config.py                   + CHAIN block
run_local.py                + --chain --restart-at --rejoin-as --tier1 --require-commit
run_server.py               + --chain, whitewash gate at enrollment
net/agent.py                + --attack profiles, /bind-wallet, commit hook
net/handles.py              REPLACE - band fix + commit_agent hook
tpm/client.py               + sign_message / verify / verify_ak_signature
eval/chain_eval.py          Chapter 5 harness (6 experiments)
eval/make_figures.py        REPLACE - FPR assertion fixed
tests/test_pipeline.py      + 4 chain groups
tests/test_chain_integration.py   9 groups
tools/prove_it_works.py     41 checks with negative controls
contracts/test/DLTFRegistryCommit.t.sol   34 Foundry tests
contracts/foundry.toml      via_ir = true, solc pinned, lint exclusion documented
contracts/out/*             prebuilt artifacts, solc 0.8.24
```

---

## Current evidence base

| Artifact | Count |
|---|---|
| module self-tests | 274 ✓ across 22 modules |
| pipeline groups | 8/8 |
| chain integration groups | 9/9 |
| falsification checks (with controls) | 41/41 |
| Python contract parity checks | 53 |
| Solidity tests | 34 |
| Chapter 4 CSVs + figures | 6 + 8 |
| Chapter 5 CSVs + figures | 9 + 5 |

---

## The five things still open

1. **Tier 7, REAL mode** — three machines. Needs a **third agent**, or detection
   silently does nothing (measured: n ≥ 3 required for median-based stages).
2. **Tier 8, live Anvil** — 10 minutes. Cheapest remaining win.
3. **solc on PATH is 0.5.16** — install 0.8.24 into `~/bin`, or just use
   `forge build`. Do not upgrade to newest: measured, it moves deploy gas by
   −49,167 and invalidates your Chapter 5 figure.
4. **`eval/plot_results.py` is a byte-identical copy of `eval/scenarios.py`** —
   your own log proved it. Delete it and drop it from `COMPILE_ONLY`.
5. **Housekeeping** — move v1 chain work to `trust/legacy/`, resolve
   `chain/reputation.py` vs `trust/reputation.py`, remove `dsadas/`, confirm
   `run_server.py` exists.

## Numbers to quote carefully

| Quote | Not |
|---|---|
| `round_gas ≈ 58,280 + 38,818 × clients` (slope exact, intercept ±5 from calldata) | a single precise intercept |
| packed word **208 bits declared** | 179 or 181 (varies with `lastRound`) |
| deploy **2,085,425** at solc 0.8.24 | any figure from another compiler |
| flag-level FPR 0.6%, **sanction-level 0%** | "zero false positives" |
| latency from `--exp real` only | SIM py-evm absolutes |
