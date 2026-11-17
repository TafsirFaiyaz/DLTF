# SETUP_GUIDE.md

Setup for DLTF, in the order things actually break. Each section says what it is
for, what to run, and what proves it worked.

Two roles:

| Role | Runs | Needs |
|---|---|---|
| **SIM** | one PC, `run_local.py` | Python only. No TPM, no network, no node. |
| **REAL** | 3 machines, `run_server.py` + `net/agent.py` | TPM + tpm2-tools + Tailscale + torch |

Sections 1–4 are required for both. 5–7 are SIM. 8–10 are REAL. 11 is the chain.

---

## 1. System packages

```bash
sudo apt update
sudo apt install -y python3 python3-pip python3-venv git curl build-essential
```

REAL mode clients also need:

```bash
sudo apt install -y tpm2-tools openssl
```

`openssl` is not optional on the client side. `verify_ek_certificate` tries the
strict Python X.509 parser first and falls back to `openssl verify
-partial_chain`, because AMD fTPM EK certificates are technically malformed
(non-spec DEFAULT encoding on a critical field) **and** chain via a partial
chain. Both paths are needed; without `openssl` a valid AMD cert silently
downgrades the device to Tier 2.

**Verify:**
```bash
python3 --version          # 3.10+ ; 3.12 tested
openssl version
```

---

## 2. Virtual environment — get this right or figures break

```bash
cd DLTF-main
python3 -m venv venv                  # NO --system-site-packages
source venv/bin/activate
python3 -m pip install --upgrade pip
```

> ### Why `--system-site-packages` must be avoided
>
> This is the exact cause of the figure failure:
>
> ```
> A module that was compiled using NumPy 1.x cannot be run in NumPy 2.4.6
> - figures skipped (numpy.core.multiarray failed to import)
> ```
>
> The traceback resolved matplotlib from `/usr/lib/python3/dist-packages`
> (system, built against NumPy 1.x) while NumPy 2.4.6 came from
> `~/.local/lib/python3.12/site-packages`. Two NumPy ABIs in one interpreter.
> matplotlib fails to import and every figure is skipped — silently, because
> `chain_eval.py` catches it and continues.
>
> An isolated venv means matplotlib and numpy come from the same place and their
> ABIs agree. Verified in a clean venv: numpy 2.5.1 + matplotlib 3.11.1 plot
> together fine.

**If you already have a polluted venv:**

```bash
deactivate 2>/dev/null
rm -rf venv
python3 -m venv venv && source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt -r requirements-chain.txt
```

**Verify the fix took:**
```bash
python3 -c "
import matplotlib; print('matplotlib from', matplotlib.__file__)
import numpy; print('numpy      from', numpy.__file__)"
```

Both paths must contain `venv/`. If either says `/usr/lib/python3/dist-packages`
or `.local`, the venv is still leaking.

---

## 3. Python dependencies

```bash
pip install -r requirements.txt              # core
pip install -r requirements-chain.txt        # chain layer (optional)
```

torch is large. SIM-only work does not need it, and the CPU wheel is much
smaller:

```bash
pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
```

> **Note on the chain pins.** `eth-tester` and `py-evm` have never shipped a
> final release — the newest are `0.13.0b1` and `0.12.1b1`. pip skips
> pre-releases unless the specifier names one, so `eth-tester>=0.12` resolves to
> nothing and fails with a wall of "Ignored the following versions".
> `requirements-chain.txt` pins the betas explicitly.

**Verify:**
```bash
python3 -c "
import numpy, cryptography, matplotlib; matplotlib.use('Agg')
import matplotlib.pyplot as plt
print('core ok')
import web3, eth_tester, eth_utils, eth_account
from eth_tester import PyEVMBackend
print('chain ok')"
```

---

## 4. Solidity toolchain — needed for the contract tests

Two tools. Either alone is enough to build; you want both.

### solc — PIN 0.8.24, do not install "latest"

First check what you actually have:

```bash
solc --version
```

Ubuntu's `apt install solc` ships **0.5.16**, a 2019 compiler. It cannot build
this contract at all (`pragma solidity ^0.8.20`), and the error it produces
mentions compiler versions rather than anything recognisable, so it reads like a
contract fault.

> #### Do NOT upgrade to the newest solc. Measured reason:
>
> I compiled the same contract with 0.8.24 and 0.8.31 and benchmarked both:
>
> | operation | 0.8.24 | 0.8.31 | delta |
> |---|---:|---:|---:|
> | **deploy** | 2,085,425 | 2,036,258 | **−49,167 (−2.36%)** |
> | register | 95,332 | 95,353 | +21 (+0.02%) |
> | classify NEUTRAL | 36,174 | 36,214 | +40 (+0.11%) |
> | roundSummary | 91,751 | 91,747 | −4 (−0.00%) |
> | bytecode | 9,941 B | 9,714 B | −227 B |
>
> Runtime gas is stable within ±0.11%, but **deploy moves by 49k gas** and the
> bytecode shrinks by 227 bytes. Newer solc means a different optimizer, so
> upgrading invalidates the deploy figure already in your thesis and forces a
> re-measure for no benefit. `chain/foundry.toml` pins `solc_version = "0.8.24"`
> for exactly this reason.

Install 0.8.24 into `~/bin` and let PATH order shadow the apt copy:

```bash
mkdir -p ~/bin && cd /tmp
curl -sL -o solc \
  https://github.com/ethereum/solidity/releases/download/v0.8.24/solc-static-linux
chmod +x solc && mv solc ~/bin/
echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc && source ~/.bashrc
hash -r
solc --version      # must read 0.8.24+commit.e11b9ed9
```

**Do not `apt remove solc`** — another package may depend on it. Shadowing via
PATH order is enough and is reversible.

**You can also skip solc entirely.** Foundry manages its own compiler through
`svm`, so `forge build` uses 0.8.24 regardless of what is on your PATH:

```bash
cd contracts && forge build && cd ..
```

If you ever genuinely need a newer compiler, the same download works with any
tag (`v0.8.31`, etc.) — but re-run `eval/chain_eval.py --exp gas` afterwards and
update every gas figure in Chapter 5.

### Foundry

```bash
curl -L https://foundry.paradigm.xyz | bash
source ~/.bashrc && foundryup
forge --version
```

If that URL is blocked:

```bash
cd /tmp
curl -sL -o foundry.tar.gz \
  https://github.com/foundry-rs/foundry/releases/download/v1.7.1/foundry_v1.7.1_linux_amd64.tar.gz
tar xzf foundry.tar.gz -C ~/bin/
forge --version
```

### Compile the contract

> ### `--via-ir` IS MANDATORY
>
> Without it:
> ```
> Error: Stack too deep ... at DLTFRegistry.sol:666 (_classifyCore)
> ```
> `chain/foundry.toml` already sets `via_ir = true`; the older solc command in
> the docs was never updated. Prebuilt artifacts ship in `contracts/out/`, so
> you can skip this — but if you rebuild, use this exact line:

```bash
solc --optimize --optimize-runs 200 --via-ir --bin --abi --overwrite \
     -o contracts/out chain/DLTFRegistry.sol
```

**Verify:**
```bash
python3 -c "
b=open('contracts/out/DLTFRegistry.bin').read().strip()
print(f'{len(b)//2} bytes  (expect 9941, EIP-170 limit 24576)')"
```

### Assemble the Foundry project

Your `forge test` reported:

```
Compiling 1 files with Solc 0.8.24
No tests found in project!
```

**1 file compiled = only `src/DLTFRegistry.sol`.** The test file is not in
`contracts/test/`. It landed in `chain/test/`. Fix:

```bash
cd DLTF-main
mkdir -p contracts/src contracts/test contracts/out contracts/lib

cp chain/DLTFRegistry.sol               contracts/src/
cp chain/test/DLTFRegistryCommit.t.sol  contracts/test/
cp chain/out/DLTFRegistry.abi chain/out/DLTFRegistry.bin contracts/out/ 2>/dev/null

cat > contracts/foundry.toml << 'EOF'
[profile.default]
src = "src"
out = "out"
test = "test"
libs = ["lib"]
solc_version = "0.8.24"
optimizer = true
optimizer_runs = 200
via_ir = true
verbosity = 3
EOF

cd contracts
forge install foundry-rs/forge-std --no-commit
echo 'forge-std/=lib/forge-std/src/' > remappings.txt
forge test -vv
```

**Verify:** `Compiling 2 files` and `34 passed; 0 failed`. If it still says
`Compiling 1 files`, the `.t.sol` did not copy.

Then drop the duplicate tomls:
```bash
cd DLTF-main
rm -f "chain/foundry (1).toml" "contracts/foundry (2).toml"
```

---

## 5. Verify the install

Run in this order — each is cheap and localises failure.

```bash
cd DLTF-main && source venv/bin/activate

# 5a. does it behave as intended?  (~60 s, 41 checks with negative controls)
PYTHONPATH=. python3 tools/prove_it_works.py

# 5b. does everything run?
PYTHONPATH=. python3 tests/test_pipeline.py            # 8 groups
PYTHONPATH=. python3 tests/test_chain_integration.py   # 9 groups

# 5c. does the contract match the spec?
PYTHONPATH=. python3 -m chain.evm_parity_test          # 15
PYTHONPATH=. python3 -m chain.commit_parity_test       # 17
PYTHONPATH=. python3 -m chain.batch_parity_test        # 21
cd contracts && forge test -vv && cd ..                # 34
```

| Command | Expect | If it fails |
|---|---|---|
| `prove_it_works.py` | `41 checks passed` | read which negative control fired |
| `test_pipeline.py` | `✓ PIPELINE GREEN` | a module is missing or broken |
| `test_chain_integration.py` | `✓ CHAIN INTEGRATION GREEN` | chain wiring problem |
| parity suites | 15 / 17 / 21 | artifacts missing, or contract ≠ spec |
| `forge test` | `34 passed` | see §4 assembly |

---

## 6. SIM mode

```bash
# baseline, no chain
PYTHONPATH=. python3 run_local.py --clients 6 --rounds 10

# attackers detected and banned
PYTHONPATH=. python3 run_local.py --clients 6 --attackers 2 --rounds 10

# Tier-1 clients, so probation becomes reachable
PYTHONPATH=. python3 run_local.py --clients 6 --attackers 2 --tier1 6 --rounds 15

# the full demo: ban -> restart -> rebuild from chain -> whitewash
PYTHONPATH=. python3 run_local.py --clients 6 --attackers 2 --rounds 20 \
    --chain mock --restart-at 12 --rejoin-as newclient
```

**The line that proves reconciliation:** round 11 ends at `0.397`, round 12
resumes at `0.400`. A wiped engine restarts at `0.292`. Continuity means the
state came off the chain.

> Without `--tier1`, every SIM client is Tier 2 → `REHAB=False` → **probation is
> unreachable.** And CRITICAL is ungated, so sybils ban outright even at Tier 1;
> exercising probation end-to-end needs a *poisoner* (sustained MAJOR).

---

## 7. Evaluation and figures

```bash
# Chapter 4: trust-model data (chain OFF), then figures
grep -rn "BAD_EVIDENCE\[.CRITICAL" eval/ trust/     # landmine check, expect nothing
PYTHONPATH=. python3 -m eval.run_experiments --exp all --seeds 5 \
    --rounds 30 --out results --check
PYTHONPATH=. python3 -m eval.make_figures           # -> results/figures/

# Chapter 5: chain layer (~4 min)
PYTHONPATH=. python3 -m eval.chain_eval --exp all --seeds 3 --rounds 10 \
    --repeats 3 --max-clients 50 --storage-rounds 30 --check
```

Order matters: `make_figures` reads `results/*.csv`. Running it first plots stale
numbers.

**Verify figures actually rendered** — they are skipped silently on an import
error:

```bash
ls -la results/figures/*.png results/chain/*.png
```

Expect 8 in `results/figures/` and 5 in `results/chain/`. If `results/chain/` has
none and the log said `- figures skipped`, go back to §2.

> `eval/plot_results.py` is a **byte-identical copy of `eval/scenarios.py`** — a
> copy-paste error; its own docstring says `eval/scenarios.py`. It generates no
> plots. `eval/make_figures.py` is the real figure generator. Delete or rewrite
> `plot_results.py`, and drop it from `COMPILE_ONLY` in `tests/test_pipeline.py`.

---

## 8. REAL mode — Tailscale

On all three machines:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up          # SAME account on all three
tailscale status           # must list ALL machines
```

Required, not optional: Bangladeshi CGNAT blocks direct inbound.

```bash
ping -c2 100.70.28.2
ping -c2 100.64.57.82
```

> ⚠ **Resolve the client2 IP conflict.** MASTER_CONTEXT says `100.73.178.45`;
> `config.py` says `100.64.57.82`. `config.py` is what runs. Make them agree — a
> stale IP looks exactly like a dead agent.

---

## 9. REAL mode — TPM and certificates

### On each client

```bash
sudo usermod -aG tss $USER      # then log out and back in
ls -l /dev/tpmrm0
tpm2_getcap properties-fixed | head
```

### Fetch the EK certificate — per machine, never shared

```bash
cd DLTF-main && mkdir -p cert
tpm2_createek -c ek.ctx -G rsa -u ek.pub
tpm2_getekcertificate -u ek.pub -o cert/ek.crt -X
PYTHONPATH=. python3 tpm/check_ek_cert.py       # expect: verifies
```

Each chip has its own cert. Copying one between machines guarantees a Tier-2
enrollment and a confusing afternoon.

`tpm/client.py` reads `cert/ek.crt` from disk **first**, live-fetch only as
fallback — AMD's PKI is flaky and has returned a different, failing 1262-byte
cert. See `FETCH_EK_CERT.md`.

### On the server — CA bundle

```bash
ls -l tpm/ca/amd_ftpm_ca.pem
openssl crl2pkcs7 -nocrl -certfile tpm/ca/amd_ftpm_ca.pem \
  | openssl pkcs7 -print_certs -noout | grep subject
```

Must contain **both** AMD intermediates (`CN=PRG-RN` *and* `CN=PRG-SSP`) plus the
AMDTPM root. Client certs chain through PRG-RN; a bundle with only PRG-SSP
silently yields `cert_ok=False` and every client lands at Tier 2.

---

## 10. REAL mode — run it

### `config.py`

```python
CLIENTS = [
    {"device_label": "client1", "tpm_backend": "real",
     "tcti": "device:/dev/tpmrm0", "endpoint": "http://100.70.28.2:8470"},
    {"device_label": "client2", "tpm_backend": "real",
     "tcti": "device:/dev/tpmrm0", "endpoint": "http://100.64.57.82:8470"},
    # third agent on the server box -- see the note below
    {"device_label": "client3", "tpm_backend": "mock",
     "endpoint": "http://127.0.0.1:8471"},
]
```

> ### ⚠ Two physical clients cannot demonstrate detection
>
> Measured, not guessed. With exactly 2 clients, `scale`, `flip` and `sleeper`
> all go **undetected**. Stage 1 compares a norm against 2.5× the median of all
> norms *including the attacker's*, and with n=2 the median lands between them:
> `[1, 10] → median 5.5 → ratio 1.82 < 2.5`. A median needs ≥3 samples.
> Stage 2's robust reference degenerates to one noisy client.
>
> A third agent (mock TPM, on the server box) restores every stage — and makes
> the federation mixed-tier, so one run shows Tier-1 probation *and* Tier-2
> immediate ban on real hardware. State the n ≥ 3 requirement in Chapter 6.

### Clients

```bash
PYTHONPATH=. python3 -m net.agent --label client1 --port 8470 --stub   # smoke
PYTHONPATH=. python3 -m net.agent --label client1 --port 8470          # real MNIST
```

### Server

```bash
curl http://100.70.28.2:8470/health      # {"ok": true, "device": "client1"}

PYTHONPATH=. python3 run_server.py --rounds 3 --stub --dim 6   # smoke
PYTHONPATH=. python3 run_server.py --rounds 10                 # real MNIST
PYTHONPATH=. python3 run_server.py --rounds 10 --chain mock    # + ledger
```

**Verify:** `client1`/`client2` show `tier HARDWARE`. If they show
`TPM_RESIDENT`, the cert chain failed — recheck §9.

### Live attack demo

```bash
# poisoning -> MAJOR -> probation (Tier 1)
PYTHONPATH=. python3 -m net.agent --label client2 --port 8470 --attack flip

# sybil collusion -> CRITICAL -> ban  (SAME seed on both, or it will not fire)
PYTHONPATH=. python3 -m net.agent --label client1 --port 8470 --attack sybil --attack-seed 1337
PYTHONPATH=. python3 -m net.agent --label client2 --port 8470 --attack sybil --attack-seed 1337

# sleeper: banks trust, then flips
PYTHONPATH=. python3 -m net.agent --label client2 --port 8470 --attack sleeper --attack-after 5
```

A lone sybil is `NEUTRAL` by design — collusion is what stage 3 detects.

### REAL-mode latency

```bash
PYTHONPATH=. python3 -m eval.chain_eval --exp real --chain off  --real-rounds 10
PYTHONPATH=. python3 -m eval.chain_eval --exp real --chain mock --real-rounds 10
PYTHONPATH=. python3 -m eval.chain_eval --exp real --chain node --real-rounds 10
```

**The only latency figures you may quote as absolutes.** Everything in Chapter
5's SIM tables runs on in-process py-evm, which over-states EVM execution
(pure-Python interpreter) while under-stating transport (no socket, no block
time).

---

## 11. Live node (optional)

```bash
anvil &                                   # or: npx hardhat node
PYTHONPATH=. python3 -m chain.deploy --network localhost
PYTHONPATH=. python3 run_server.py --rounds 10 --chain node
```

Address is written to `chain/deployed.json`. Resolution order: `--address` >
`config.CHAIN["contract_address"]` > `deployed.json`.

Keep Anvil bound to localhost. The server is the only authorised writer; the
contract enforces that with `UnauthorizedWriter`, but there is no reason to
expose the RPC.

---

## 12. Troubleshooting

| Symptom | Cause |
|---|---|
| `ModuleNotFoundError` on any DLTF module | missing `PYTHONPATH=.` |
| `- figures skipped (numpy.core.multiarray failed)` | venv leaking system packages — §2 |
| `Stack too deep` from solc | missing `--via-ir` |
| `No tests found in project!` | `.t.sol` not in `contracts/test/` — §4 |
| `Command 'forge' not found` … `apt install snap` | Ubuntu guessing; Foundry is not a snap — §4 |
| `eth-tester` has no matching distribution | needs the beta pin — §3 |
| `artifacts not found` | run the solc command, or use shipped `contracts/out/` |
| `TypeError: cannot unpack non-iterable bool` | placeholder `audit/hashchain.py` |
| `TPM_RESIDENT` instead of `HARDWARE` | cert missing / wrong CA bundle / `tpm_backend` not `"real"` |
| `tpm2_createek: permission denied` | not in `tss` group, or no re-login |
| attack runs, nothing flagged | only 2 clients — §10 |
| probation never fires | missing `--tier1`; and CRITICAL bypasses rehab |
| `--restart-at needs --chain` | working as intended |
| `--chain node` cannot connect | `anvil` not running, or no `chain/deployed.json` |
| node dies mid-run | expected: round marked UNANCHORED, training continues |

### Full green baseline

| Suite | Expect |
|---|---|
| `tools/prove_it_works.py` | 41 checks, 0 failed |
| `tests/test_pipeline.py` | 8/8 groups |
| `tests/test_chain_integration.py` | 9/9 groups |
| module self-tests | 274 ✓ across 22 modules |
| `forge test` | 34 passed |
| `eval/run_experiments.py --check` | all evaluation checks passed |
| `eval/chain_eval.py --check` | CHAIN EVAL GREEN |

### Never commit

```gitignore
venv/
results/
contracts/out/
contracts/lib/
chain/deployed.json
cert/
__pycache__/
*.pyc
```

`results/federation.key` is the HMAC key for EK privacy. **If it leaks, anyone
can test whether a given EK is in your banned set** and the N22 privacy property
is gone. Treat it as a private key.
