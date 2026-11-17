# MASTER_CONTEXT.md — DLTF Thesis, Current State

Complete context for continuing the DLTF thesis in a new session. This describes
the system AS IT STANDS NOW, with every constant read back from live code.
Read fully before touching code.

User: Sazzad, CS undergraduate thesis, BRAC University, defending Summer 2026.
Style: terse, direct, bottom-line-first, tables over prose, wants short answers,
corrects verbosity and factual/citation errors directly. House code style: no em
dashes, ✓/✗ in prints, minimal comments, every module has a `__main__` self-test
with assertions, comments map features to objectives O1–O4.

> **v3 REWRITE NOTICE.** The previous MASTER_CONTEXT described the v2.1
> reputation engine (per-tier priors (8,2)/(4,2)/(2,2), start trust
> 0.80/0.667/0.50, per-tier γ, `w(MINOR)=1 w(MAJOR)=3`, θ_r=0.55,
> FORGIVE_AFTER=5, FORGET=0.95 Tier-1-only). **None of those values are in the
> code any more.** §4 below is re-derived from `trust/reputation.py` as it
> actually is. It also declared "no smart contracts in the current codebase";
> that is also obsolete — see §11.

---

## 1. What DLTF is

DLTF (Decentralized Learning Trust Framework): a federated-learning security
system that decides how much to trust each client's gradient based on
hardware-proven identity, sanctions misbehavior so attackers cannot escape by
re-registering, and rehabilitates devices that provably reform.

Four objectives (cited throughout the code):
- O1 Sybil resistance — one TPM chip = one identity (credential activation).
- O2 Anti-whitewashing — bans bind to the TPM's EK hash, survive re-registration.
- O3 Quantified trust — deterministic reputation formula + measured attacker cost.
- O4 Aggregator-agnostic — trust layer outputs plain weight dicts.

Novelty (NOT detection — that uses existing techniques): (a) hardware-rooted
sanction-and-rehabilitation lifecycle, (b) the sanction *policy* is a function of
hardware trust tier (identity replacement cost), (c) attacker cost per tier is
quantified, (d) **v3 addition:** the ban ledger is independently verifiable by a
party that does not trust the server (§11).

---

## 2. Live deployment state

WORKING: 3 physical machines on a Tailscale WireGuard mesh (account tpm97510@),
all Ryzen boxes with AMD firmware TPMs:
- 100.95.144.127 (ubuntu)    → SERVER (runs `run_server.py`; NOT in CLIENTS)
- 100.70.28.2   (s4zz4d HP)  → client1 (runs `net/agent.py`)
- client2       (tafsir HP)  → **IP DISAGREES BETWEEN SOURCES, see below**

> ⚠ **client2 IP conflict.** The old MASTER_CONTEXT said `100.73.178.45`;
> `config.py` and NEXT_SESSION_PROMPT say `100.64.57.82`. `config.py` is what
> actually runs, so it wins unless you re-check `tailscale status`. Resolve this
> before the live demo — a stale IP looks exactly like a dead agent.

ACHIEVED: Both clients enroll as real Tier 1 (HARDWARE) with DISTINCT EK hashes
(client1 ac6971…, client2 e7c273…), confirming one-chip-one-identity (O1). Real
409,034-param MNIST model is sent by the server. Round loop runs over real HTTP.
Audit chain writes to `results/audit.jsonl`.

Deployment facts:
- Tailscale is required (Bangladeshi CGNAT blocks direct inbound). All machines
  must be on ONE Tailscale account or only some appear in `tailscale status`.
- The SERVER dials OUT to clients on port 8470; clients never dial the server,
  so the server's own IP is not in `config.CLIENTS`.
- torch + torchvision needed on SERVER and all CLIENTS (server imports MNISTModel).
- Traffic is WireGuard-encrypted, mitigating the plain-HTTP limitation.

---

## 3. TPM / hardware attestation — RESOLVED

Both clients reach real Tier 1. Certs live per-machine in `cert/` (each chip has
its OWN cert; certs are NOT shared between machines). Verified chain:
EK cert → AMD intermediate → AMD root; `verify_ek_certificate` returns True.

Key facts and fixes already applied:
- Cert is read from disk (`cert/ek.crt`), NOT live-fetched at enroll time. AMD's
  PKI live-fetch is flaky and returned a different (failing) 1262-byte cert.
  `_try_ek_cert` in `tpm/client.py` reads the on-disk cert first; fetch is only a
  fallback.
- `run_server.py` loads `tpm/ca/amd_ftpm_ca.pem` as `ca_bundle_pem` and passes it
  to FederatedServer. Without it `cert_ok` is always False → all Tier 2.
- CA bundle must contain the RIGHT intermediate. AMD chips chain through
  different intermediates: client certs use CN=PRG-RN, but the original bundle
  only had CN=PRG-SSP. Bundle now includes BOTH intermediates + AMDTPM root.
- `verify_ek_certificate` (`tpm/common.py`) tries the strict Rust X.509 parser
  first, falls back to `openssl verify -partial_chain` on ANY failure (parse OR
  chain-walk), because AMD certs are technically malformed (non-spec DEFAULT
  encoding on a critical field) AND chain via partial_chain. Both paths needed.

Enrollment tier gate (`fl/server.py`): tier is HARDWARE only if
`cert_ok = (cert present) AND (ca_bundle loaded) AND verify_ek_certificate()`
AND credential activation passes. The tier the SERVER assigns depends on what the
AGENT provisions (its `tpm_backend`), not on files sitting in `cert/`.

**v3 addition — wallet binding** (`tpm/client.py`): `sign_message(bytes)` signs
arbitrary bytes with the AK via `tpm2_sign` (RSASSA/SHA-256), and
`verify_ak_signature(ak_pub, msg, sig)` is the server-side check. Deliberately
SEPARATE from `sign_challenge`, which produces a `tpm2_quote` over PCRs and is
not a signature over caller-supplied bytes — overloading it would have silently
produced unverifiable wallet bindings.

DATA MODEL (enrollment, JSON over HTTP, binary fields base64):
```
ek_cert    ≜ ⟨EK_pub, issuer, validity, manufacturer_sig⟩
provision  ≜ ⟨device_label, ek_hash, ak_name, ek_cert, ek_pub⟩   POST /enroll
challenge  ≜ ⟨blob⟩  blob = MakeCredential(ek_pub, secret)       POST /activate
response   ≜ ⟨secret'⟩  secret' = ActivateCredential(blob)
identity   ≜ ⟨device_label, ek_hash, tier, status⟩
ek_hash = SHA256(EK_pub) is the identity fingerprint; bans bind to it (O2).
```

> ⚠ `check_tiers.py` is referenced in the old quick-start but **is not in the
> tree**. Either write it or drop the reference.

---

## 4. Reputation engine — v3, FINALIZED (`trust/reputation.py`)

Bayesian engine in subjective-logic form (Josang 2001; Josang & Ismail 2002).
Class `ReputationEngine`. Exports `Status`, `EventTier`, `PROBATION_WEIGHT_CAP`.

TRUST SCORE (Josang's probability expectation E = b + a·u):

```
T = (α₀ + s) / (α₀ + β₀ + s + f)
```

### THE v3 DESIGN DECISION: trust is TIER-NEUTRAL

This is the single biggest change from v2.1 and it is a *better* story, so lead
with it. In v2.1 the tier was baked into the prior, so Tier 1 started at 0.80
and Tier 3 at 0.50 — which made "trust" and "identity assurance" the same axis
and invited the objection that a Tier-1 attacker gets a head start it never
earned.

In v3 **every tier uses the same uniform Beta(1,1) prior and the same dynamics.**
Verified from live code:

| | HARDWARE | TPM_RESIDENT | SOFTWARE |
|---|---|---|---|
| prior (α₀, β₀) | (1, 1) | (1, 1) | (1, 1) |
| start trust T₀ | 0.500 | 0.500 | 0.500 |
| trust ceiling | 0.8333 | 0.8333 | 0.8333 |
| γ | 0.90 | 0.90 | 0.90 |

Tier enters at exactly **three** places, none of them the score:
1. **weight cap** `D` — aggregation weight `w = D(tier) · T`
2. **rehab eligibility** `REHAB` — who gets probation instead of a ban
3. **EK ban binding** — only a real EK can be banned durably

So: *behaviour determines trust; hardware determines consequences.* Verified
start weights: HW 0.500, T2 0.250, T3 0.050 — all from the same T₀ = 0.5.

### CONSTANTS (read back from `trust/reputation.py`)

```
W_PRIOR       = 2.0    [CITED]  Josang non-informative prior weight
BASE_RATE     = 0.5    [CITED]  insufficient reason
PRIOR         = (1,1)  [CITED]  = (W·a, W·(1−a)), UNIFORM across tiers
THETA         = 0.4    [CITED]  Kang 2019 Table I, positive interaction weight
TAU           = 0.6    [CITED]  Kang 2019 Table I, negative > positive
GAMMA         = 0.9    [CONVENTIONAL] uniform decay
FORGET        = 0.90   [DERIVED] = GAMMA. ONE decay primitive, not two.
FORGIVE_AFTER = 2      [CALIBRATED] probation W_MIN + 1... see note
MAJOR_RUN_TO_ESCALATE = 2   [CALIBRATED] repetition begins at 2
PROBATION_T   = 0.5    [CALIBRATED] indifference point (Kang trusted-worker)
REINSTATE_T   = 0.75   [DERIVED] closed form PROBATION_T·(1 + 1/W_PRIOR)
BAN_T         = 0.3    [CALIBRATED] backstop; probation fires first on rehab tiers
TIER_DISCOUNT = {HW 1.0 [CANONICAL], T2 0.5 [CALIBRATED], T3 0.1 [CALIBRATED]}
REHAB         = {HW True, T2 False, T3 False}
GOOD_EVIDENCE = {POSITIVE: 0.4, NEUTRAL: 0.4}
BAD_EVIDENCE  = {MINOR: 0.6, MAJOR: 0.6}     CRITICAL is a RULE, not a weight
S_MAX         = THETA/(1−GAMMA) = 4          goodwill ceiling
TRUST_CEILING = (1+S_MAX)/(W_PRIOR+S_MAX) = 0.8333
PROBATION_WEIGHT_CAP = d3 = 0.1              suspect ≤ unproven identity
```

**MINOR and MAJOR carry the SAME evidence weight (0.6).** They differ only in
that MAJOR feeds `major_run`, which drives the M3 escalation rule. This replaces
v2.1's 1-vs-3 weighting. Be ready for "then why two severities?" — the answer is
that severity selects the *rule* (repetition tracking), not the *magnitude*.

**FORGET = GAMMA = 0.90 is [DERIVED], not calibrated.** v2.1 had two independent
decay constants (0.95 for distrust, per-tier γ for trust) and justified the
asymmetry with Slovic. v3 collapses them to one primitive; the asymmetry now
comes from *when* forgetting is allowed (only after `FORGIVE_AFTER` clean rounds,
M2), not from a different rate. One fewer free parameter.

### HARDENING MECHANISMS

- **M1 bounded recency**: `s ← γ·s + θ` each good round, saturating at
  `θ/(1−γ) = 4`. A sleeper cannot bank unbounded cushion.
- **M2 earned forgetting**: `f` is sticky and never decays round-by-round; it
  fades (`×0.90`) only after `FORGIVE_AFTER = 2` consecutive clean rounds. One
  good round launders nothing — defeats on-off attacks.
- **M3 sustained escalation**: 2 consecutive MAJORs → probation/ban **bypassing
  the score**, so a high-`s` veteran sleeper is caught even while T > 0.5.
- **Cold-start gate**: the score path is gated on the opinion being
  evidence-dominated (`u < 0.5 ⇔ s + f > W_PRIOR = 2`), so a device cannot be
  sanctioned on its first noisy round. M3 is UNGATED (a rule, not a score).
- **D5 due process**: an ACTIVE rehab-tier device hitting even `BAN_T` gets
  PROBATION first; the backstop bans only from PROBATION onward.

### VERIFIED SANCTION PATHS (live code output)

| Tier | 2× MAJOR | 1× CRITICAL | 4× MINOR |
|---|---|---|---|
| HARDWARE | ACTIVE → **PROBATION** | **BANNED** | ACTIVE×3 → **PROBATION** |
| TPM_RESIDENT | ACTIVE → **BANNED** | **BANNED** | ACTIVE×3 → **BANNED** |
| SOFTWARE | ACTIVE → **BANNED** | **BANNED** | ACTIVE×3 → **BANNED** |

Cold-start gate in action (Tier 3, repeated MINOR):

```
after 1 MINOR: s+f=0.60  evidence_dominated=False  T=0.385  ACTIVE
after 2 MINOR: s+f=1.20  evidence_dominated=False  T=0.312  ACTIVE
after 3 MINOR: s+f=1.80  evidence_dominated=False  T=0.263  ACTIVE
after 4 MINOR: s+f=2.40  evidence_dominated=True   T=0.227  BANNED
```

T drops below `BAN_T` at round 2 but no sanction fires until the gate opens at
round 4. That is the cold-start protection, measured.

METHODS: `register(id,tier,ek_hash)` / `record_event(id,severity)` /
`reinstate(id, trial_rounds=0)` / `get_status` / `get_weight` / `get_all_weights`
/ `get_opinion(id) → (b,d,u,a)` / `rank(ids=None)` → Josang Def.10 ordering /
`banned_ek_hashes`.

> `reputation.py` is a **strict black box** for the chain layer. No edits.
> Interaction is via public API; state injection uses `setattr` / `_dev` patching.
> It has one latent hole: `register(id, tier)` with `ek_hash=None` resurrects a
> BANNED device as ACTIVE. Unreachable from `server.py`. The chain layer catches
> it — that is the demo. **Do not "fix" it in reputation.py.**

---

## 5. Probation engine — FINALIZED (`trust/probation.py`)

Tier-1-only rehabilitation. A probated client's updates train an ISOLATED shadow
model (frozen global snapshot + only that client's gradients). Reinstatement is
decided by the OLS slope of the shadow model's accuracy over the trial.

```
REINSTATE_SLOPE  = 0.005   → REINSTATED (calls rep.reinstate with trial rounds)
EXTEND_SLOPE     = 0.001   → one-shot EXTENDED (+3 rounds), else PERMANENT_BAN
EXTENSION_ROUNDS = 3
WINDOW_MIN, WINDOW_MAX = 4, 9    [DERIVED] OLS sign-stability floor; K1−1 ceiling
SLOPE_ESTIMATOR  = "ols"   ("theil_sen" available for noisy MNIST)
WINDOW = HMAC(device_id, entry_round) ∈ [4, 9], salt = os.urandom per process
```

The per-process HMAC salt blocks "behave just long enough" timing attacks.

SLOPE→REPUTATION COUPLING: the slope decides the BRANCH; the trial rounds are
forwarded as `rep.reinstate(id, trial_rounds=len(accuracy_series))` — EARNED
evidence (`s += trial_rounds · θ`) applied before the **REINSTATE_T = 0.75**
floor. A longer proven recovery returns with proportionally higher trust. Note
the floor is 0.75 in v3, not v2.1's 0.55. Duck-typed engine interface.

One-shot: a reinstated device that re-offends hits REHAB_EXHAUSTED → permanent
ban, no second trial.

---

## 6. Detection (`trust/filter.py`) — existing techniques, max-severity compose

```
Stage1  norm > 2.5× median                                  → MINOR
Stage2  cosine to leave-one-out median of prior-trusted < −0.45  → MAJOR
Stage3  FoolsGold-style pairwise sim ≥ 0.95 sustained 2 rounds   → CRITICAL
Stage4  self-history cosine < −0.45 sustained 2 rounds            → MAJOR
MIN_HISTORY = 3   HISTORY_WINDOW = 10   REF_MIN_WEIGHT = 0.0
```

Detection is explicitly NOT the contribution. It is the input to the trust layer.

---

## 7. Architecture

```
tpm/     identity: EK cert verify + credential activation → tier; wallet signing
trust/   reputation.py (§4), probation.py (§5), filter.py (§6)
fl/      model (MNIST CNN 409k), dataset (non-IID), client, aggregator
         (fedavg/krum/trimmed_mean), server (enroll + round lifecycle)
net/     handles.py (local↔remote seam), agent.py (per-client HTTP agent)
audit/   hashchain.py (HMAC-signed tamper-evident JSONL chain)
chain/   OPTIONAL on-chain trust registry (§11)
eval/    scenarios, run_experiments (Ch.4 CSVs), plot_results, chain_eval (§11)
tests/   test_pipeline.py, test_chain_integration.py
```

Trust model: server trusted for *training*; clients untrusted; only manufacturer
roots/intermediates in the CA bundle are trusted. Weight = `D(tier)·T`; banned
devices absent from weights → structurally excluded. Krum uses weights as an
eligibility mask (O4).

**v3 change to the trust model:** the chain layer removes the server from the
trusted set *for the ban ledger specifically*. See §11.

### THREE INDEPENDENT AXES

| Axis | Options | Selector |
|---|---|---|
| TPM | mock / swtpm / real | `make_signer`, `config.CLIENTS[].tpm_backend` |
| Transport | in-process / HTTP | `LocalClientHandle` / `RemoteClientHandle` |
| Chain | off / mock / node | `--chain`, `config.CHAIN["mode"]` |

All nine combinations run. SIM = `run_local.py`, REAL = `run_server.py` +
`net/agent.py`.

---

## 8. `audit/hashchain.py` — the local ledger

```python
HashChain(path=None, key=None)
.append(event_type, payload) -> entry dict
.entries(event_type=None) -> list[dict]
.verify() -> (bool, err|None)
.head_hash() -> hex
.__len__() -> int
```

Entry: `{seq, ts, type, payload, prev, hash, sig}`. GENESIS auto-appended.

> ⚠ A "minimal, compatible stand-in" version of this file has been circulating
> in the repo. It exposes `entries` as an ATTRIBUTE, returns a bare `bool` from
> `verify()`, stores `data` instead of `payload`, and has no `head_hash`. That
> version breaks `chain/registry.py`, `chain/verifier.py`, AND
> `tests/test_pipeline.py` (which calls `entries()`, unpacks `ok, err =
> verify()`, and calls `head_hash()`). Check yours:
> `grep -n "def verify\|self.entries\|def head_hash" audit/hashchain.py`

---

## 9. Related work positioning (Ch.2 / defense)

- **FoolsGold [Fung 2018]**: gradient-similarity detection only; no identity, no
  cost to re-register. DLTF includes a FoolsGold-style stage but adds
  hardware-bound identity that detection binds to.
- **Kang 2019/2020** (multi-weight subjective logic FL reputation): flagship
  citation, and in v3 the **direct source of θ = 0.4 and τ = 0.6** (Table I).
  v3 uses their weights rather than avoiding them, which is now defensible
  because the tier no longer lives in the prior — there is no tier prior for
  their values to erase. Sui 2024 documents Kang's new-vs-old-client flaw = the
  same flaw the supervisor flagged.
- **Josang 2001** (subjective logic): the formal foundation. DLTF's trust formula
  IS his E = b + a·u; his Def.10 = DLTF's `rank()`. W=2, a=0.5 are his.
- **Wang 2022** (TPM + blockchain oracle FL): uses TPM for update INTEGRITY, not
  persistent identity binding. DLTF binds identity so bans survive re-join.
  ⚠ **Still missing from REFERENCES.md.**
- **Friedman & Resnick 2001** (cheap pseudonyms) + **Ostrom 1990** (graduated
  sanctions): justify tier-coupling (policy scales with identity cost).
- ⚠ Reference [24] Domingo-Ferrer marked VERIFY.
- **Honesty rule**: no paper prescribes `d2=0.5`, `d3=0.1`, `FORGIVE_AFTER=2`,
  `BAN_T=0.3`, or `MAJOR_RUN_TO_ESCALATE=2`. Those are [CALIBRATED] by DLTF's own
  sweep. Claiming a citation for them = fabricated citation. Defend by
  derivation and sweep, not citation.

---

## 10. Known limitations (state ALL in thesis)

X.509 path validation simplified (name chain + signatures; no revocation / full
RFC 5280 / EK-profile OIDs). Plain HTTP at request level (mitigated by
Tailscale/WireGuard; request-level auth is future work). Tier 1 only where a
verifiable EK cert exists — the claim is "whitewashing becomes
hardware-cost-bound", never "impossible". Synthetic substrate for trust metrics;
MNIST accuracy machine-side. Small federation (2 real / ≤50 simulated). Several
constants remain [CALIBRATED] inside derived bounds — defended by the sweep.
Uncertainty `u` never reaches 0 (bounded memory) — deliberate; it is what defeats
sleepers.

**Resolved in v3:** ~~in-memory engine state (restart = re-enroll)~~ — see N23
in §11. Trust state now survives restart.

**New in v3:** reconciliation restores TRUST state, not MODEL state — the global
parameter vector is not on chain and is carried in-process across a restart. A
real deployment checkpoints it separately. Orthogonal to the trust claim, but
state it. Also, the on-chain ban check FAILS OPEN when the node is unreachable
(failing closed would hand a node-DoS attacker a federation-wide enrollment
DoS); the staleness window is a stated limitation.

---

## 11. Chain layer — OPTIONAL on-chain trust registry (v3, NEW)

> This **supersedes** the old §7 note that said "no smart contracts in the
> current codebase … do not reintroduce blockchain". The earlier Polygon
> iteration (`trust/chain_bridge.py`, `trust/ReputationRegistry.sol`,
> `trust/deploy_chain.py`) is v1 and is superseded by `chain/`. Decide whether
> to move v1 to `legacy/` before submission — two implementations in the import
> path invites "which one is the contribution?"

### What it is for

The local audit log is verifiable but **centralized**: a reader must trust the
server that wrote it. The chain layer makes the O2 ban ledger checkable by a
party that does not trust the server, and makes bans survive a restart.

### Guarantees

| ID | Guarantee |
|---|---|
| N20 | Semantic API: callers submit severity, the contract recomputes. No `submitState()`, so a server cannot assert an arbitrary score. |
| N21 | Six rejection rules enforced **by EVM revert**, not by Python. |
| N22 | EK privacy: only `ek_hmac = HMAC(fed_key, "DLTF-EKv1\|" + ek_hash)` goes on chain. Raw EK hashes never leave the host. |
| N23 | **Bans survive restart.** `chain/reconcile.py` rebuilds a live `ReputationEngine` from chain events. |
| N24 | Never on the critical path. Node down → round marked UNANCHORED, training continues. |
| N25 | Commitment layer: clients commit `keccak256(canonical(gradient))` before sending, so the server cannot fabricate an update and attribute it. |

### Rejection rules (all tested on the deployed contract)

| Rule | Custom error |
|---|---|
| BANNED → ACTIVE resurrection | `BanToActive` |
| tier change after enrollment | `TierMutation` |
| duplicate / stale round | `DuplicateRound` / `StaleRound` |
| one EK, two device ids | `EkAlreadyRegistered` |
| write from non-server address | `UnauthorizedWriter` |
| classify on unknown / banned | `DeviceUnknown` / `DeviceBanned` |

### Reconciliation reads TWO ledgers, and must

| What | Source | Why |
|---|---|---|
| `s`, `f`, `clean_run`, `major_run`, `status`, `tier` | **chain** | authoritative because the contract rejected any write breaking the lifecycle |
| raw `ek_hash` | **local audit log** | the chain only holds the one-way HMAC |

`register()` decides O2 with `ek_hash in self._banned_ek`, where `ek_hash` is the
RAW hex the handle presents. Seeding that set with HMAC digests would leave it
non-empty, make every lookup miss, and **silently re-admit every banned device**.
`chain/reconcile.py` test 6 is a permanent regression guard.

### Files

```
chain/fixedpoint.py    integer mirror of reputation.py (SCALE = 1e6)
chain/backend.py       abstract Backend ABC + Reason codes
chain/mock.py          deterministic in-memory backend (CI, no node)
chain/keys.py          FederationKey (ek_hmac privacy)
chain/registry.py      HashChain-compatible adapter; drops into audit=
chain/verifier.py      third-party recomputation from events
chain/commit.py        gradient commitment + EIP-712 batch signing
chain/reconcile.py     rebuild ReputationEngine from chain (N23)
chain/wiring.py        --chain flag -> audit object (shared by both run scripts)
chain/evm.py           live-node backend (web3.py)
chain/deploy.py        deploy + chain/deployed.json
chain/DLTFRegistry.sol the contract
eval/chain_eval.py     evaluation harness
```

`ChainRegistry` implements the HashChain surface exactly, so it drops into
`FederatedServer(audit=registry)` with **zero changes to `fl/server.py`**.

`fl/server.py` line 113 skips NEUTRAL classifications, so the adapter **infers**
NEUTRAL from the complement of logged EVENTs against the ROUND participant list.
Exact, not heuristic.

### Fixed-point parity

`chain/fixedpoint.py` is an integer mirror at `SCALE = 1e6`. Proven bound
`|T_float − T_fixed| ≤ 5e-6`, zero measured status divergence. Bit-parity with
the deployed contract verified after every write.

### Commitment layer is WIRED END TO END (v3.1)

`config.CHAIN["require_commit"]` used to be a dead knob -- nothing read it. Now:

- `chain/wiring.py` wraps the mock backend in `CommitMockBackend` on request,
  and for node mode CHECKS the deployed `requireCommit` matches (it is
  immutable, so a mismatch raises rather than being silently ignored)
- `net/handles.py` `LocalClientHandle` accepts `commit_agent` and commits
  BEFORE `train()` returns, mirroring `net/agent.py` over HTTP
- `run_local.py --require-commit` binds a wallet per device via a TPM AK
  signature, then attaches a `CommitAgent`
- `chain/verifier.py` knows `WALLET_BOUND` / `GRADIENT_COMMITTED` /
  `COMMIT_PROOF` / `COMMIT_MISMATCH` are non-state events

```bash
PYTHONPATH=. python3 run_local.py --clients 5 --attackers 2 --rounds 8 \
    --chain mock --require-commit
```
```
commitment: 5 wallets bound to TPM identities, clients now commit before sending
VERIFIED: 5 devices, 33 events replayed, 0 discrepancies
```

### ⚠ solc IS PINNED TO 0.8.24 -- do not upgrade

Measured, same contract, 0.8.24 vs 0.8.31:

| operation | 0.8.24 | 0.8.31 | delta |
|---|---:|---:|---:|
| deploy | 2,085,425 | 2,036,258 | **-49,167 (-2.36%)** |
| register | 95,332 | 95,353 | +0.02% |
| classify NEUTRAL | 36,174 | 36,214 | +0.11% |
| bytecode | 9,941 B | 9,714 B | -227 B |

Runtime gas is stable; DEPLOY moves by 49k. Upgrading invalidates the Chapter 5
deploy figure for no benefit. Ubuntu's `apt install solc` gives 0.5.16, which
cannot build this contract at all.

### ⚠ `--via-ir` IS MANDATORY

The old quick-start command **fails**:

```
Error: Stack too deep ... at DLTFRegistry.sol:666 (_classifyCore)
```

`chain/foundry.toml` already sets `via_ir = true` ("classifySigned exceeds the
16-slot stack limit otherwise"); the solc command was never updated. Correct:

```bash
solc --optimize --optimize-runs 200 --via-ir --bin --abi --overwrite \
     -o contracts/out chain/DLTFRegistry.sol
```

Bytecode: **9,941 bytes (9.7 KB)**, EIP-170 limit 24,576. (Earlier docs said
6.5 KB and 8.9 KB; both predate `--via-ir`.)

### Measured results (`eval/chain_eval.py`, solc 0.8.24, optimizer 200, via-IR)

| Operation | Gas |
|---|---:|
| deploy | 2,085,425 |
| register (fresh) | 95,344 |
| classify NEUTRAL (warm) | 36,186 |
| classify MINOR / MAJOR (warm) | 35,961 / 36,046 |
| classify CRITICAL → BAN | 62,075 |
| roundSummary | 91,367 |
| register (banned EK, whitewash) | 27,358 |
| bindWallet | 71,630 |
| commitGradient (CLIENT pays) | 51,653 |

**Cost model:** `round_gas = 58,282 + 38,818 × clients`, R² = 1.000000.
Affine, not proportional — `roundSummary` is a fixed per-round cost. At 6
clients: **291,180** (earlier docs said ~309,000).

| Property | Measured |
|---|---|
| Parity chain off vs mock vs node | **exactly 0.000e+00**, 6/6 configs |
| Storage drift over 30 rounds | 0.15% ⇒ device state is O(devices) |
| Packed device word | 181 bits of 256 (one SSTORE slot) |
| Reconcile 200 rounds of history | 2.3–3.3 ms rebuild, 2.2 ms verify |
| Mock-chain round overhead | ≤ 1.8 ms |

⚠ **In-process py-evm latency does not transfer, in either direction.** It is a
pure-Python interpreter: it over-states execution vs Anvil/Geth and under-states
transport (no socket, no block time). Quote absolute latency only from
`--exp real` on the physical machines.

---

## 12. Test status

**274 ✓ checks green** across 22 modules.

```bash
PYTHONPATH=. python3 tests/test_pipeline.py           # whole stack + chain
PYTHONPATH=. python3 tests/test_chain_integration.py  # 9 groups
PYTHONPATH=. python3 -m chain.reconcile               # 16
PYTHONPATH=. python3 -m chain.wiring                  # 10
PYTHONPATH=. python3 -m chain.evm                     # 17  (eth-tester)
PYTHONPATH=. python3 -m chain.deploy --self-test      #  7  (eth-tester)
PYTHONPATH=. python3 -m chain.evm_parity_test         # 15  (deployed contract)
PYTHONPATH=. python3 -m chain.commit_parity_test      # 17
PYTHONPATH=. python3 -m chain.batch_parity_test       # 21
```

> ⚠ `net/handles.py:99` asserts `0.3 <= w <= 0.5`. Under v3 a fresh Tier-2
> device after one NEUTRAL round is `s=0.4, f=0 → T=0.5833 → w=0.2917`, so it
> **fails**. This is a v2.1 leftover, the same staleness class as the Chapter-4
> CSVs. Fix: `0.25 <= w <= 0.35`. Grep for siblings:
> `grep -rn "0\.3 <=\|<= 0\.5" --include=*.py .`

---

## 13. Quick start

### SIM (one PC, no hardware)

```bash
# baseline, no chain
PYTHONPATH=. python3 run_local.py --clients 6 --rounds 10

# Tier-1 clients so probation is reachable
PYTHONPATH=. python3 run_local.py --clients 6 --attackers 2 --tier1 6 --rounds 15

# full chain demo: ban -> restart -> rebuild -> whitewash
PYTHONPATH=. python3 run_local.py --clients 6 --attackers 2 --rounds 20 \
    --chain mock --restart-at 12 --rejoin-as newclient
```

> Without `--tier1`, every SIM client is Tier 2 → `REHAB=False` → **probation is
> unreachable**. This was a long-standing gap in the SIM harness.

### REAL (three machines, Tailscale)

```bash
# each CLIENT, leave running
PYTHONPATH=. python3 -m net.agent --label client1 --port 8470

# SERVER: health check first
curl http://100.70.28.2:8470/health          # expect {"ok":true}
PYTHONPATH=. python3 run_server.py --rounds 10           # real MNIST, no chain
PYTHONPATH=. python3 run_server.py --rounds 10 --chain mock
```

### Live node

```bash
anvil &                                       # or: npx hardhat node
PYTHONPATH=. python3 -m chain.deploy --network localhost
PYTHONPATH=. python3 run_server.py --rounds 10 --chain node
```

### Evaluation

```bash
# Chapter 4 (chain OFF) -- MUST BE RE-RUN, see §14
PYTHONPATH=. python3 -m eval.run_experiments --exp all --seeds 5 \
    --rounds 30 --out results --check

# Chapter 5 chain layer
PYTHONPATH=. python3 -m eval.chain_eval --exp all --seeds 3 --rounds 10 \
    --repeats 3 --max-clients 50 --storage-rounds 30 --check

# REAL-mode latency (the only quotable absolute latency)
PYTHONPATH=. python3 -m eval.chain_eval --exp real --chain node --real-rounds 10
```

---

## 14. PENDING / next steps

**⚠ BLOCKER — re-run Chapter 4.** Every file in `results/` was generated under
v2.1 at FORGET = 0.95 with per-tier priors. Under v3 (uniform Beta(1,1),
FORGET = 0.90, MINOR == MAJOR weight) **every trust trajectory shifts**. Nothing
in Chapter 5 can be finalized until Chapter 4's numbers are stable. The
`net/handles.py:99` failure in §12 is the same staleness surfacing in a
self-test, which is good reason to believe the CSVs really are stale rather than
close enough.

```bash
PYTHONPATH=. python3 -m eval.run_experiments --exp all --seeds 5 \
    --rounds 30 --out results --check
```

Before re-running: `grep -rn "BAD_EVIDENCE\[.CRITICAL" eval/ trust/` — CRITICAL
is not a `BAD_EVIDENCE` key; any code reading it will KeyError.

Remaining build work:
- **Step 11**: `chain/DLTFRegistry.t.sol` needs Foundry tests for `bindWallet`,
  `commitGradient`, and the anti-fabrication rule. The Python parity suites
  already cover this against the deployed bytecode, so the value is
  *independence*. Lowest-yield remaining item.
- **REAL-mode latency table** (`--exp real`) on the physical machines.
- **Live poison-injection demo** over Tailscale: real flag → ban → EK-bound
  whitewash rejection.

Housekeeping:
- Resolve the client2 IP conflict (§2).
- Decide v1 vs v2 chain: move `trust/chain_bridge.py`,
  `trust/ReputationRegistry.sol`, `trust/deploy_chain.py`, `trust/test_parity.py`,
  `build/registry_dev.json` to `legacy/`.
- `chain/reputation.py` duplicates `trust/reputation.py` — diff and delete the
  loser. Same for `chain/MASTER_CONTEXT.md` vs root.
- `check_tiers.py` referenced but absent — write it or drop the reference.
- Add Wang 2022 to REFERENCES.md; verify reference [24].
- Remove stray `dsadas/` and check `chain/files/`.
- Fix `net/handles.py:99` band.
