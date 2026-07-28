# QB22 — Config-Change Data-Processing Runaway

**Detects:** per-GB data-processing spend (NAT-gateway bytes, cross-AZ transfer, traffic
inspection) that steps up sharply and *stays* elevated **while compute stays flat**.

That combination is the fingerprint of a **networking/routing config change shipped without
cost guardrails** — a new NAT path, a re-routed egress, an inspection/firewall policy — rather
than organic growth. Real growth moves compute *and* data-processing together; a config change
moves only the bytes. Left alone it bleeds quietly for weeks because no single day looks alarming.

## Run it

From the `./run.sh` prompt. Three acts, each answering a different question:

```sql
.read queries/qb22-config-change-data-processing-runaway/preflight.duckdb.sql    -- CHECK: can this data answer the question?
.read queries/qb22-config-change-data-processing-runaway/diagnostic.duckdb.sql   -- LEARN: the ranked field, rules as pass/fail flags
.read queries/qb22-config-change-data-processing-runaway/query.duckdb.sql        -- TRUST: what actually fires
```

Against the sample bill the detector returns **1 row**. Run
`python3 tools/verify_corpus.py` to check every pattern at once.

**Reading a zero row.** Zero rows with every preflight check `PASS` is a real, honest zero —
the bill is clean on this pattern. Zero rows with any check `FAIL` means the data cannot
answer the question at all, which is a blind spot, not a clean bill.

## The triad (all three must hold, per subaccount)

| Signal | Rule | Why |
|---|---|---|
| **Step** | recent data-processing daily cost ≥ **2.5×** the prior-30-day baseline | the runaway itself |
| **Flat compute** | recent compute daily cost < **1.3×** its baseline | rules out a real traffic surge |
| **Persistence** | elevated on ≥ **5 of the last 7** days | rules out a one-day blip |
| _(floor)_ | data-processing spend over last 7d ≥ **$50** | suppresses trivial noise |

## Reading the output

| Column | Meaning |
|---|---|
| `dp_step_ratio` | how many× data-processing spend jumped vs baseline (the runaway) |
| `compute_growth` | ~1.0 confirms compute didn't move — the key discriminant |
| `dp_recent_7d` | dollars in the last 7 days (what you'd save by reverting) |
| `onset_day` | first elevated day — line this up with your change log / IaC history |

## Columns used

`subaccountid`, `chargeperiodstart`, `chargecategory`, `chargeclass`, `servicename`,
`x_usagetype` (AWS Data Exports extension — the per-GB usage-type string), `billedcost`.

## Limitations

- Needs ~60 days of history (30-day baseline + recent window).
- `x_usagetype` is an AWS extension; Azure/GCP equivalents vary — the `LIKE` lists cover the
  common NAT/cross-AZ/inspection usage types but tune them to your provider's vocabulary.
- It flags the *billing shape*; confirm the specific route/policy change in your change history
  (the `onset_day` is your anchor).

## Files

| File | Dialect | Purpose |
|---|---|---|
| `query.sql` | Athena / Trino | The detector — run it against your own FOCUS table (keeps confirmed hits only). |
| `query.duckdb.sql` | DuckDB | The same detector, for the local playground. |
| `diagnostic.duckdb.sql` | DuckDB | Teaching view — ranks the top subaccounts and shows the triad as pass/fail flags, so you can see the anomaly separate from normal accounts. |

## Try it locally

From the repo root run `./run.sh`, then at the DuckDB prompt:

```
-- see the mechanics: top subaccounts ranked, with the three rules as flags
.read queries/qb22-config-change-data-processing-runaway/diagnostic.duckdb.sql

-- the detector: keeps only the confirmed hit
.read queries/qb22-config-change-data-processing-runaway/query.duckdb.sql
```

The bundled sample data plants exactly this pattern on one AWS subaccount — open
`samples/guide.html` for the expected finding.
