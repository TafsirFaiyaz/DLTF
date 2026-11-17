# DLTF Chain Layer

An optional on-chain trust registry that enforces the DLTF trust-lifecycle
rules independently of the FL server. It is **off by default**; enabling it
never removes a guarantee, only adds one.

## What this layer guarantees

Six things the server cannot do while this layer is enabled:

| Rule | Enforced by |
|---|---|
| A **BANNED** device cannot become **ACTIVE** by any path | `BanToActive` custom error |
| A device's **tier** cannot change after enrollment | `TierMutation` |
| A reputation delta outside the published rule | Structural — no delta API surface |
| A duplicate or out-of-order **round id** | `DuplicateRound`, `StaleRound` |
| Re-enrolling a **registered EK** under a different device | `EkAlreadyRegistered` |
| Any write from **non-server** address | `UnauthorizedWriter` |

Every rule has a corresponding revert test in
`chain/evm_parity_test.py` and `contracts/test/DLTFRegistry.t.sol`.

## What this layer does NOT guarantee

Documented up front so nobody has to ask at defense:

* **Truthfulness of classifications.** A compromised server key can still
  emit `MAJOR` against an honest client. The contract constrains the
  transition rule given a classification, not the classification itself.
  Mitigating this requires either multi-party classification consensus or
  ZK proofs of update validity; out of scope for this thesis.
* **Decentralisation.** A local Hardhat/Anvil node has no consensus
  properties. The trust properties this layer would gain from a public
  ledger are contingent on deployment across independent validators. This
  work evaluates the *mechanism*, not the deployment.
* **Long-term storage.** Immutable ledgers conflict with GDPR-style
  erasure. The `ek_hmac` layer (HMAC-SHA256 of the EK hash under a
  federation-scoped key) mitigates the fingerprinting risk but does not
  provide erasure. If a federation key is destroyed, existing `ek_hmac`s
  become unlinkable to any physical machine — this is the closest
  approximation to erasure the design supports.

## Mode-selection table

The three axes (TPM identity × transport × chain) are independent. All
combinations work; these four are the ones that matter:

| TPM | Transport | Chain | Command | Purpose |
|---|---|---|---|---|
| mock | in-process | off | `python3 run_local.py --clients 6 --rounds 20` | Sweeps, CI, iteration (existing) |
| mock | in-process | mock | `DLTF_CHAIN=mock python3 run_local.py --chain mock --clients 6 --rounds 20` | Rejection tests, restart demo, reconciliation |
| mock | in-process | node | `DLTF_CHAIN=node python3 run_local.py --chain node --clients 6 --rounds 20` | Gas / latency measurement, scale tests |
| real | HTTP | off | `python3 run_server.py --rounds 15` | Hardware validation without chain overhead (existing) |
| real | HTTP | mock | *(rarely useful — mock chain doesn't survive process death)* | — |
| real | HTTP | node | `python3 run_server.py --chain node --rounds 15` | The thesis demo |

## Copy-pasteable commands

### CI / self-tests

```bash
# Trust engine + fixed-point mirror + parity
PYTHONPATH=. python3 -m trust.reputation      # 16 checks
PYTHONPATH=. python3 -m chain.fixedpoint      # 14 checks (2000×40 parity)
PYTHONPATH=. python3 -m chain.keys            # 10 checks
PYTHONPATH=. python3 -m chain.backend         #  5 checks
PYTHONPATH=. python3 -m chain.mock            # 20 checks
```

### Deployed-contract parity (needs solc)

```bash
# Compile once
solc --optimize --optimize-runs 200 --bin --abi --overwrite \
     -o contracts/out contracts/src/DLTFRegistry.sol

# Run parity harness against py-evm (no live node needed)
PYTHONPATH=. python3 -m chain.evm_parity_test   # 13 checks
```

### With a live node (Hardhat or Anvil)

```bash
# Terminal 1 (server machine)
anvil                                          # or: npx hardhat node

# Terminal 2
PYTHONPATH=. python3 -m chain.deploy --network localhost
```

Note: the on-chain node **must** be bound to `localhost` on the server
machine only. The server is the only writer; exposing the node to the
tailnet would let a client attempt to write directly (the contract's
`onlyServer` modifier would refuse it, but the exposure is unnecessary).

### With Foundry (independent verification)

```bash
cd contracts && forge test -vvv
```

The Foundry test file (`contracts/test/DLTFRegistry.t.sol`) is an
independent verification path. The Python harness is authoritative for
spec compliance because it runs the same contract from the same code
path Python uses in production.

## Fixed-point arithmetic (why it agrees bit-for-bit)

The reputation rule in `trust/reputation.py` uses floats. Solidity has no
floats. `chain/fixedpoint.py` mirrors the float engine using integer
arithmetic at `SCALE = 10⁶`, chosen so that every constant is exactly
representable (`THETA = 400_000`, `TAU = 600_000`, thresholds all with
small denominators).

Only one operation truncates: `decay(x) = (9 * x) // 10`. Solidity's `/`
on `uint256` is floor; Python's `//` on non-negative `int` is floor.
They agree by construction, not approximately.

Threshold checks are done by cross-multiplication (`(1 + s) * SCALE
<= t * (2 + s + f)`), which is exact.

**Provable bound**: `|T_float − T_fixed| ≤ 5×10⁻⁶`. Measured over
80,000 random events across all three tiers: **zero status decisions
differ** between the float engine and the integer path.

## Storage cost

One packed 256-bit slot per device: `s` (64) + `f` (64) + `cleanRun`
(16) + `majorRun` (16) + `status` (8) + `tier` (8) + `lastRound` (32) =
208 bits, with 48 bits reserved. One **warm** `SSTORE` per device per
round.

Measured gas costs on py-evm (Cancun, optimizer runs = 200):

| Operation | Gas |
|---|---:|
| Deploy contract | 1,397,314 |
| `register` (fresh device) | 95,047 |
| `classify NEUTRAL` (cold slot) | 36,332 |
| `classify NEUTRAL` (warm slot) | 36,593 |
| `classify MAJOR` (warm slot) | 36,380 |
| `roundSummary` (fresh round) | 91,277 |
| `classify CRITICAL → BAN` | 64,346 |
| `register` (banned EK → whitewash) | 27,153 |

At 20 gwei / $2000 ETH: a warm classify is ~$0.0015. Per-round cost with
6 active devices is ~$0.10.

## Availability & degradation

Chain writes are **never on the critical path**. If the node is
unreachable, a transaction times out, or a revert fires unexpectedly,
the round must not stall. `chain.backend.Backend.is_available()`
returns `False` in that case; `registry.py` degrades to the local
`audit/hashchain.py` and marks the round `UNANCHORED`, to be reconciled
when the node returns.

At enrollment: if the node is unreachable, DLTF fails **open** against
a cached snapshot of the ban list. This is a deliberate choice —
failing closed would hand any attacker who can DoS the node a way to
DoS enrollment for the whole federation. The staleness window is a
documented limitation.

## File map

```
chain/
  fixedpoint.py       — integer arithmetic (mirror of trust/reputation.py)
  backend.py          — abstract Backend API + Event + ChainRejection
  mock.py             — deterministic in-memory Backend (CI, rule testing)
  keys.py             — FederationKey: HMAC-SHA256 EK privacy layer
  evm_parity_test.py  — deployed-contract parity harness (needs solc)

  # PENDING (next batch):
  # evm.py            — web3.py adapter for a live Hardhat/Anvil node
  # registry.py       — HashChain-compatible adapter (drops into FederatedServer)
  # deploy.py         — deployment script
  # verifier.py       — third-party recomputation from events alone
  # reconcile.py      — rebuild ReputationEngine state at startup

contracts/
  src/DLTFRegistry.sol      — the contract
  test/DLTFRegistry.t.sol   — Foundry tests (mirror of parity harness)
  foundry.toml              — Foundry config
  out/                      — solc build artifacts (generated)
```
