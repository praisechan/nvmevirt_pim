# SwarmIO inflash_pim — Run Order

Scripts for emulating INFLASH/PIM storage on the **i9-13900F** (32 logical CPUs,
`memmap=16G$96G`, no Intel DSA).  All scripts are safe to dry-run without `RUN=1`.

---

## 1. Build the module

```bash
cd /path/to/nvmevirt_pim/SwarmIO
bash scripts/build.sh -i configs/inflash_pim.conf
```

`build.sh` reads the `[build]` section of `inflash_pim.conf` (sets `skip_io=1`,
disables DMA, enables faithful per-plane timing) and runs `sudo make install`.

---

## 2. Unload nvmev (if loaded)

`nvmev` and `swarmio` both claim the reserved memmap region — only one can be
loaded at a time.

```bash
lsmod | grep -E 'nvmev|swarmio'   # check current state
sudo rmmod nvmev                  # unload if needed
```

---

## 3. Load SwarmIO

```bash
# Dry-run (prints command, no sudo):
bash SwarmIO/scripts/load_inflash.sh

# Faithful variant (38 us round, default):
RUN=1 bash SwarmIO/scripts/load_inflash.sh

# Sweep service-unit counts:
RUN=1 NUM_SERVICE_UNITS=1 bash SwarmIO/scripts/load_inflash.sh
RUN=1 NUM_SERVICE_UNITS=2 bash SwarmIO/scripts/load_inflash.sh
RUN=1 NUM_SERVICE_UNITS=4 bash SwarmIO/scripts/load_inflash.sh
RUN=1 NUM_SERVICE_UNITS=8 bash SwarmIO/scripts/load_inflash.sh   # default

# Pipelined variant (read_sched_delay=8000 ns, read_min_delay=30000 ns):
RUN=1 PIPELINED=1 bash SwarmIO/scripts/load_inflash.sh
```

After loading, discover the new block device:

```bash
lsblk | grep nvme          # find /dev/nvmeXn1
sudo dmesg | tail -20      # verify swarmio params in kernel log
export DEV=/dev/nvme1n1    # set for subsequent steps
```

---

## 4. Calibration microtests

Verify timing model before running the full fio sweep.
Requires `host/inflash_bench` (pre-built at `REPO_DIR/host/inflash_bench`).

```bash
# Faithful variant expectations:
#   Test A (1 req)    → ~38 us
#   Test B (same inst)→ ~76 us
#   Test C (512 par)  → ~38 us
DEV=/dev/nvme1n1 bash SwarmIO/scripts/swarmio_microtest.sh

# Pipelined variant expectations:
#   Test B → ~46 us
DEV=/dev/nvme1n1 PIPELINED=1 bash SwarmIO/scripts/swarmio_microtest.sh
```

Bench is pinned to E-cores 16-31 (`BENCH_CPUS` env, default `16-31`),
disjoint from service-unit CPUs 2-9.

---

## 5. fio sweep

```bash
export VDEV_DEV_NAME=nvme1n1   # device discovered in step 3

bash SwarmIO/scripts/run_fio.sh \
    -i configs/inflash_pim.conf \
    -n 1,2,4,8 \
    -d 1,4,16,64 \
    -j 1,4,8
```

fio workers are pinned to E-cores 16-31 via `FIO_CPUS` (env, default `16-31`).
Results land in `SwarmIO/results/fio/trace/`.

---

## 6. Unload

```bash
RUN=1 bash SwarmIO/scripts/unload_inflash.sh
```

---

## Timing model reference

| Variant   | `read_sched_delay` | `read_min_delay` | T(1 req) | T(same inst×2) | T(512 par) |
|-----------|--------------------|------------------|----------|----------------|------------|
| Faithful  | 38 000 ns          | 0 ns             | ~38 us   | ~76 us         | ~38 us     |
| Pipelined | 8 000 ns           | 30 000 ns        | ~38 us   | ~46 us         | ~38 us     |

`T_model(N) = 38 000 × ceil(N / 512)` ns — matches one scheduling round per 512 instances.

### CPU layout (i9-13900F)

| Role            | Cores  | Notes                        |
|-----------------|--------|------------------------------|
| OS / IRQ        | 0-1    | left free                    |
| SwarmIO SUs     | 2-9    | P-cores (HT), `cpus=2-9`    |
| fio / bench     | 16-31  | E-cores, fully disjoint      |
| Spare P-cores   | 10-15  | available for other workloads|
