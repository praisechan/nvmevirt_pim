# SwarmIO In-Flash Compute — CSV Schema Contract

This document specifies the **machine-readable CSV schema** for SwarmIO measurement results
(Task D.3 in `SWARMIO_INFLASH_COMPUTE_EMULATION_PROMPT.md`). Raw-measurement emitters
(sweep scripts, `inflash_bench`, fio wrappers) and the model/plotting scripts all conform
to this contract.

---

## Header line

```
harness,num_service_units,N_or_iodepth,qdepth,threads,T_model_ns,measured_e2e_ns,measured_MIOPS,abs_err,rel_err
```

- One header line, comma-separated, **no spaces around commas**, all lowercase.
- Column order is fixed; parsers may rely on position.

---

## Column semantics

| # | Column              | Type    | Units   | Description |
|---|---------------------|---------|---------|-------------|
| 1 | `harness`           | string  | —       | Measurement harness. One of: `nvmevirt` (io_uring baseline against NVMeVirt INFLASH_PIM), `swarmio` (inflash_bench against SwarmIO), `swarmio_fio` (fio sweep against SwarmIO via `run_fio.sh`). |
| 2 | `num_service_units` | integer | —       | SwarmIO service units configured at load time. One of `{1, 2, 4, 8}` for SwarmIO rows. Set to `0` for `nvmevirt` rows (no service-unit concept). |
| 3 | `N_or_iodepth`      | integer | —       | Total concurrent requests (N) for `inflash_bench` sweeps, or effective concurrency `iodepth × numjobs` for fio runs. **Primary independent variable.** Sweep values: `{1,2,4,8,16,32,64,128,256,512,1024,2048,4096}`. |
| 4 | `qdepth`            | integer | —       | NVMe submission queue depth. For `inflash_bench`: equals `N_or_iodepth`. For fio: the per-job `iodepth`. |
| 5 | `threads`           | integer | —       | Host-side threads / fio jobs. `1` for `inflash_bench` runs. |
| 6 | `T_model_ns`        | integer | ns      | Analytic model prediction. Populated by `scripts/swarmio_model.py`. Faithful config: `38000 × ⌈N / 512⌉`. Pipelined config: `30000 + 8000 × ⌈N / 512⌉`. Set to `0` in raw emitter output (before enrichment). |
| 7 | `measured_e2e_ns`   | integer | ns      | Measured **batch end-to-end latency**: wall-clock from first I/O submit to last completion (median over trials). For fio: median `clat` in nanoseconds from fio output. |
| 8 | `measured_MIOPS`    | float   | MIOPS   | Measured throughput. For `inflash_bench`: `N / measured_e2e_ns × 10⁶` (= `N × 10³ / measured_e2e_ns`). For fio: steady-state IOPS from `/proc/swarmio/stat` ÷ 10⁶. Set to `0.0` if not applicable or not measured. |
| 9 | `abs_err`           | integer | ns      | Absolute error: `measured_e2e_ns − T_model_ns`. Positive = measured slower than model. Set to `0` if `T_model_ns == 0`. |
|10 | `rel_err`           | float   | decimal | Relative error: `(measured_e2e_ns − T_model_ns) / T_model_ns`. Decimal fraction (e.g. `0.17` = +17%, `-0.05` = −5%). Set to `0.0` if `T_model_ns == 0`. |

---

## Value constraints

- All integer columns must be non-negative (except `abs_err` which may be negative).
- `rel_err` is signed: positive means measured latency exceeds model (model over-predicts
  parallelism); negative means measured latency is below model.
- Columns `T_model_ns`, `abs_err`, `rel_err` are **enrichment columns** — they MUST be
  filled by `scripts/swarmio_model.py` before plotting. Raw emitters set them to `0`/`0.0`.
- `harness` must be exactly one of `nvmevirt`, `swarmio`, `swarmio_fio` (no spaces).
- `num_service_units` for `swarmio`/`swarmio_fio` rows: one of `{1, 2, 4, 8}`.

---

## Model parameter summary

| Config       | `read_sched_delay` | `read_min_delay` | `num_sched_insts` | T_model(N)                          | T_max        |
|:-------------|-------------------:|-----------------:|------------------:|:------------------------------------|:-------------|
| Faithful     | 38 000 ns          | 0 ns             | 512               | `38000 × ⌈N/512⌉` ns               | ≈ 13.5 MIOPS |
| Pipelined    |  8 000 ns          | 30 000 ns        | 512               | `30000 + 8000 × ⌈N/512⌉` ns        | 64 MIOPS     |

---

## Example rows

```
harness,num_service_units,N_or_iodepth,qdepth,threads,T_model_ns,measured_e2e_ns,measured_MIOPS,abs_err,rel_err
nvmevirt,0,1,1,1,38000,36000,0.0278,-2000,-0.052632
nvmevirt,0,8,8,1,38000,45000,0.1778,7000,0.184211
nvmevirt,0,512,512,1,38000,557000,0.9192,519000,13.657895
nvmevirt,0,4096,4096,1,304000,4240000,0.9660,3936000,12.947368
swarmio,1,512,512,1,38000,0,0.0,0,0.0
swarmio,4,512,512,1,38000,0,0.0,0,0.0
swarmio,8,512,512,1,38000,0,0.0,0,0.0
```

*(SwarmIO rows have `0` placeholders — run `swarmio_model.py` after measurement.)*

---

## Workflow

```
[1] Measurement run
    host/inflash_bench --csv raw.csv          (sets T_model_ns=0, abs_err=0, rel_err=0.0)
    OR
    fio + awk wrapper → raw.csv

[2] Enrich with model
    python3 scripts/swarmio_model.py raw.csv enriched.csv
    python3 scripts/swarmio_model.py --pipelined raw.csv enriched_pipelined.csv

[3] Plot
    bash scripts/swarmio_plot.sh enriched.csv [output_dir/]
    (produces PNGs via gnuplot, or markdown-table fallback if gnuplot absent)
```
