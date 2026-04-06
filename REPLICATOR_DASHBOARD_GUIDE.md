# Replicator Grafana Dashboard Guide

A practical guide to monitoring your PostgreSQL-to-CockroachDB migration using the Replicator Grafana dashboard.

## Quick Health Check

When you open the dashboard, the **"At a glance"** row at the top answers the three most important questions:

| Question | What to look at | Healthy | Action needed |
|----------|----------------|---------|---------------|
| Is replication keeping up? | **Lag Time** (source + target) | Under 60 seconds (green) | Over 60s (red) — check staging and apply sections below |
| Is data flowing? | **Throughput** (rows/sec) | Steady, non-zero | Drops to zero — replicator may have stalled |
| Is the replicator running? | **Instances** | Shows expected count | Missing instances — check container logs |

If everything in this row is green and non-zero, your migration is healthy. No need to dig deeper unless you're troubleshooting.

---

## Dashboard Sections Explained

### 1. Lag Time

**What it shows:** How far behind the replicator is from live data.

- **Source lag** = time between the latest PostgreSQL WAL checkpoint and now
- **Target lag** = time between the latest CockroachDB commit and now
- **P95 view** = the lag experienced 95% of the time (filters out one-off spikes)

**When to worry:** Source lag climbing steadily means the replicator can't keep up with write volume. Target lag climbing means CockroachDB writes are slowing down.

**What to do:**
- High source lag only → check PostgreSQL WAL throughput and network between PG and replicator
- High target lag only → check CockroachDB load, indexes, and connection pool section below
- Both climbing → replicator is overwhelmed; consider scaling or reducing source write rate

---

### 2. Source to Stage / Source to Apply Commit Lag

**What it shows:** Breaks total lag into two phases so you can isolate bottlenecks.

```
PostgreSQL WAL → [Stage Lag] → Replicator Staging Area → [Apply Lag] → CockroachDB
```

- **Stage lag** = how long from PG commit to replicator receiving and staging the change
- **Apply lag** = how long from staging to successfully writing to CockroachDB

**When to worry:** If stage lag is high but apply lag is low, the bottleneck is ingestion. If apply lag is high but stage lag is low, the bottleneck is writing to CockroachDB.

---

### 3. Errors and Warnings

**What it shows:** Rate of failed operations over time.

- **Apply errors** = mutations that failed to write to CockroachDB
- **Stage errors** = mutations that failed during staging

**When to worry:** Any non-zero error rate. Errors mean data may not be reaching CockroachDB. This is the most critical panel for data integrity.

**What to do:**
- Check replicator container logs for specific error messages
- Common causes: schema mismatches, unique constraint violations, connection timeouts
- If errors spike after a schema change, verify the target schema matches

---

### 4. HTTP (Failback/Webhook Mode Only)

**What it shows:** Health of the webhook connection when CockroachDB sends changefeeds back to the replicator during failback.

- **HTTP Latency** = how long webhook deliveries take
- **HTTP Status Codes** = 2xx (success), 4xx (client error), 5xx (server error)
- **HTTP Payload Size** = size of changefeed batches

**When to worry:** 4xx/5xx status codes appearing, or latency spiking above 1 second.

**What to do:**
- 401/403 errors → JWT token may have expired; regenerate with `make-jwt`
- 5xx errors → replicator is overloaded; check staging and apply sections
- This section is inactive during forward replication (PG→CRDB) — only relevant during failback

---

### 5. Staging Operations

**What it shows:** Performance of the replicator's internal staging phase, where incoming mutations are buffered before being applied.

- **Stage Latency P50/P75/P95/P99** = how long staging takes at different percentiles
- **Stage Activity** = mutations being staged per second
- **Redelivery Rates** = mutations being retried
- **Stage Error Rates** = failures by table

**When to worry:** P99 stage latency above 500ms, or redelivery rates climbing.

**What to do:**
- High stage latency → check the staging database (`_replicator` schema in CockroachDB) for disk or CPU pressure
- High redelivery rates → transient errors causing retries; check for lock contention

---

### 6. Sequencer Pipeline

**What it shows:** The internal processing pipeline that reads staged mutations in order and prepares them for apply.

- **Sweepers** = background processes scanning for new staged mutations
- **Sweep/Merge Latency** = how long sequencing takes
- **Stage Read Throughput** = how fast mutations are being read from staging

**When to worry:** Sweep latency spikes or read throughput drops to zero.

**Note:** If you're using custom userscripts for data transformation, script execution time and error rates also appear here.

---

### 7. Apply Operations

**What it shows:** The final step — writing mutations to the target database.

- **Apply Latency P50/P75/P95/P99** = write latency to CockroachDB
- **Apply Activity** = upserts and deletes per second
- **Table Apply P99** = per-table write latency (identifies slow tables)
- **Table Mutation Age P99** = how old the mutations being applied are (growing = falling behind)
- **Apply Error Rates** = failures by table

**When to worry:**
- P99 apply latency above 100ms → target is under write pressure
- Mutation age growing → replication is falling further behind
- One table has much higher P99 than others → that table may need index tuning

**What to do:**
- Check CockroachDB's own metrics for hot ranges or overloaded nodes
- Review indexes on slow tables
- Consider increasing replicator parallelism if available

---

### 8. Best Effort Mode

**What it shows:** When the replicator can't apply mutations through the normal ordered path, it can fall back to "best effort" mode.

- **Direct Writes** = applied immediately without full ordering guarantees
- **Deferred Writes** = queued for later retry

**When to worry:** High deferred writes indicate the target can't keep up with the incoming mutation rate. This is a leading indicator that lag will increase.

**What to do:** Address the root cause in the apply operations section — usually target database pressure.

---

### 9. DB Pool

**What it shows:** Database connection pool health for both the staging and target databases.

- **Connection Counts** = active vs idle connections
- **Acquisition Blocking Time** = how long threads wait for a connection
- **Pool Dial Latency** = time to establish new connections
- **Statement Cache Hit Rate** = efficiency of prepared statement reuse

**When to worry:**
- Blocking time spikes → all connections are in use; threads are waiting
- Dial latency above 1 second → network issue or database overload
- Cache hit rate below 80% → excessive prepared statement churn

**What to do:**
- If blocking time is high, check if the target database has enough capacity
- If dial latency is high, check network connectivity and DNS resolution
- Connection pool size is configured in replicator startup flags

---

### 10. Scheduler Performance and Userscripts

**What it shows:** Internal task scheduling and custom script execution metrics.

- **Task Wait Latency** = how long tasks queue before executing
- **Script Execution Times** = per-function, per-table timing
- **Rows Processed/Filtered** = what your custom scripts are doing
- **Function Errors** = script failures by table

**When to worry:** Only relevant if you have custom userscripts configured. High script execution time becomes a pipeline bottleneck.

---

## Common Scenarios

### "Can we cut over to CockroachDB?"

Check these conditions:
1. Source lag < 5 seconds (near real-time)
2. Target lag < 5 seconds
3. Apply errors = 0
4. Stage errors = 0
5. Row counts match between PostgreSQL and CockroachDB (use `checkcounts` in the pipeline)

If all five conditions hold, it's safe to proceed with the cutover.

### "Replication suddenly stopped"

1. Check **Instances** — did the replicator container crash?
2. Check **Throughput** — did it drop to zero?
3. Check **Errors** — did a spike of errors precede the stop?
4. Check container logs: `docker logs replicator_forward`

### "Lag keeps growing and won't recover"

1. Check **Apply Latency P99** — is the target slow?
2. Check **DB Pool blocking time** — are connections exhausted?
3. Check **Stage vs Apply lag** — where is the bottleneck?
4. Check CockroachDB admin UI for hot ranges or resource exhaustion

### "One table is much slower than others"

1. Check **Table Apply P99** — which table?
2. Check **Table Mutation Age P99** — is that table's age growing?
3. Common fixes: add indexes on the target table, check for wide rows, look for contention on hot keys

### "Failback webhook is failing"

1. Check **HTTP Status Codes** — what error codes?
2. Check **HTTP Latency** — is the replicator responding?
3. 401/403 → regenerate JWT token
4. Connection refused → replicator container may be down
5. Verify the changefeed is still running: `SHOW CHANGEFEED JOBS` in CockroachDB

---

## Prometheus Alert Rules

The following alerts are pre-configured in `prometheus_rules.yml` and fire automatically:

| Alert | Condition | Severity | Meaning |
|-------|-----------|----------|---------|
| SourceLagCritical | source_lag > 60s for 2m | Critical | Replication is significantly behind |
| TargetLagWarning | target_lag > 30s for 2m | Warning | Target writes are lagging |
| ApplyErrorsCritical | Any apply errors | Critical | Data may not be reaching target |
| StageErrorsWarning | Any stage errors | Warning | Ingestion failures |
| HighPoolDialLatency | P99 dial > 1s for 3m | Warning | Connection issues |

These alerts appear in the Prometheus UI at `http://localhost:9090/alerts`.

---

## Key Metrics Reference

| Metric | Type | What it measures |
|--------|------|-----------------|
| `source_lag_seconds` | Gauge | Lag from source WAL to replicator |
| `target_lag_seconds` | Gauge | Lag from replicator to target commit |
| `apply_upserts_total` | Counter | Total upserts applied to target |
| `apply_deletes_total` | Counter | Total deletes applied to target |
| `apply_errors_total` | Counter | Failed apply operations |
| `stage_mutations_total` | Counter | Total mutations staged |
| `stage_errors_total` | Counter | Failed staging operations |
| `apply_duration_seconds` | Histogram | Apply operation latency |
| `stage_duration_seconds` | Histogram | Stage operation latency |
| `pool_dial_latency_seconds` | Histogram | DB connection establishment time |
| `http_latency_seconds` | Histogram | Webhook delivery latency (failback) |
| `http_status_codes_total` | Counter | HTTP response codes (failback) |
