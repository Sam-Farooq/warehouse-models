# warehouse-models

A transaction analytics warehouse in dbt on BigQuery. Transactions come from
the medallion output that `lakehouse-pipeline` writes. Accounts come from a
second and separate upstream: a CRM snapshot that has no producer in that repo
and is declared here as a source in its own right. SQL is the product, and the
only Python is the offline test harness in `macro_tests/`.

```
silver.transactions  ─┐
crm.accounts         ─┤
seeds/currencies     ─┼──►  staging (4 views)
seeds/mcc_categories ─┘           │
                                  ▼
                   int_transactions_enriched  (ephemeral)
                                  │
                                  ▼
                          fct_transactions ──┬──► fct_category_daily
                      (incremental, 3 days)  │
                                             ├──► int_transactions_sequenced
                                             │        └──► fct_velocity_alerts
                                             ├──► int_account_currency_daily
                                             │        └──► fct_account_currency_daily
                                             └──► dim_accounts
```

12 models, 104 dbt tests, 38 macro unit tests. Nothing in CI opens a
connection to BigQuery.

## The marts

| Mart | Grain | How it loads |
|---|---|---|
| `fct_transactions` | transaction | incremental, static `insert_overwrite` over 3 days |
| `fct_account_currency_daily` | account, currency, day | incremental, reads 31 days and writes 3 |
| `fct_category_daily` | category group, currency, day | incremental, 3 days |
| `fct_velocity_alerts` | transaction | incremental, 3 days |
| `dim_accounts` | account | full table rebuild |

Staging reads **silver** rather than gold. The gold layer upstream has
already fixed its grain at account and day, and four of these five marts need
the transaction itself.

`lakehouse-pipeline` publishes only gold to BigQuery; its silver layer is a
Delta table partitioned by `event_date` in object storage. So this project
reads silver through a BigLake external table over those partition files. That
table is a prerequisite rather than something this repo creates, and it is the
answer to the obvious question about a dbt source pointing at a lakehouse
layer that was never loaded into the warehouse.

## Currency is part of the key, not an attribute

There is no FX rate table anywhere in the medallion output, so this warehouse
never converts and never sums across currencies. An account that trades in
EUR and GBP gets two rows a day in `fct_account_currency_daily`, and a
dashboard that wants one number has to pick a currency or pick a count.

That is more work for whoever builds the dashboard. It is the only version of
the table where every total is true. Inventing a rate, or defaulting one to
1.0, produces a column that is wrong by an amount nobody can see and that no
test can catch, because the arithmetic is all internally consistent.

The one place currency arithmetic happens is `to_minor_units()`, which scales
an amount by its own currency's exponent for exact integer comparisons.
`seeds/currencies.csv` carries 31 currencies: the exponent is 0 for CLP, ISK,
JPY, KRW and VND, 3 for BHD, JOD, KWD and TND, and 2 for the other 22. Silver
admits five currencies today, all of them two-decimal, so the zero and three
decimal rows in that seed are exercised by the macro's unit tests and not yet
by live data. That is worth knowing before anyone treats the column as
proven.

## insert_overwrite, and the part of it that bites

Every incremental model here uses `insert_overwrite` with a static partition
list, and not the `merge` that dbt-bigquery defaults to.

`merge` has to locate the matching rows, and BigQuery has no index to locate
them with. Without an `incremental_predicates` hint it scans the whole target,
so the cost of a run is a function of how much history the table holds rather
than of the day being loaded. Two years in, loading today costs two years.
`insert_overwrite` with a declared partition list rewrites exactly those
partitions, so the cost is a function of the window and stays there.
`fct_transactions` also sets `copy_partitions`, which makes the swap itself a
copy job rather than a query.

What it costs: the write is idempotent per partition, not per row. If a
transaction's `event_date` is ever corrected so that it moves out of the
replaced window, the old copy stays where it is and the table holds it twice.
Silver deduplicates on `transaction_id` and derives `event_date` from
`occurred_at`, so dates do not drift in normal operation, and a genuine
correction is a `--full-refresh` of the affected partitions rather than
something these models handle.

The window lives in one place, `reprocess_window_days` in `dbt_project.yml`,
and two macros read it. `incremental_window()` writes the `WHERE` clause and
`partition_window()` writes the partition list. If those two ever disagree,
the run reads a span it never writes, every number comes out correct, and
nothing anywhere fails. `macro_tests/test_macros.py` asserts they agree for
windows of 1, 3, 7 and 31 days.

## Two models read more than they write

A window function cannot see a row the `WHERE` clause already removed, so a
model that computes one has to read wider than its output.

`int_transactions_sequenced` reads 4 days and writes 3. A transaction at 00:04
needs the one from 23:58 the night before to know its own gap. Filter the
input to the write window and `seconds_since_prev` is null for the first
transaction of every account every single day.

`fct_account_currency_daily` reads 31 days and writes 3. The extra 28 are the
trailing baseline it computes. A trailing average over a window the `WHERE`
clause truncated is an average over whatever survived, which on the first day
of a backfill is one row.

Both trailing frames are `RANGE` over `unix_date(event_date)` rather than
`ROWS`. `ROWS 28 PRECEDING` counts rows, and a row only exists on a day the
account transacted, so for an account that moves twice a month the `ROWS`
version reaches back fourteen months and still calls itself a 28 day
baseline. `RANGE` counts calendar days and simply has fewer rows in the frame,
which is why `active_days_trailing` is published next to the averages and
`has_usable_baseline` exists at all.

## The sequence column that had to be replaced

`int_transactions_sequenced` first carried a `txn_seq` from
`row_number() over (partition by account_id order by occurred_at)` across the
whole read window. It was wrong, and wrong in a way that each individual run
looked fine.

The read window slides. One run numbers an account's transactions starting
from the oldest day it read; the next run reads a window starting a day later
and numbers the same rows from a different baseline. Partitions written by
different runs end up holding numbers from different origins, so `txn_seq`
was not comparable between two rows of the same table and was not stable for
any row across runs.

It is now `txn_seq_in_day`, scoped to the account's day, which is both
reproducible and a definition somebody can state. The `monotonic_within_group`
test asserts it increases with `occurred_at` inside every account day, which
is the invariant the sliding version could not have passed.

## Alert flags are exclusive, which is a choice

`fct_velocity_alerts` classifies each transaction with one priority-ordered
`CASE`: `rapid_fire`, then `country_hop`, then `round_amount`, then `none`.
Four boolean columns derive from that single expression.

So a transaction that satisfies two rules is reported under the first, and a
count of `rapid_fire` rows is not a count of transactions that triggered the
rapid-fire rule. Independent booleans would keep both, at the price of one row
appearing in three dashboards and a total that double counts. Exclusive is the
version an analyst can sum.

The thresholds are in `dbt_project.yml`: 6 transactions an hour, 1800 seconds
for a country change, a 5000 floor for round amounts. They are conventions.
Nothing in this repo measured them, and whether any of them is right is a
question for whoever owns the alert queue. The round-amount floor is in
display units, so it means something different in JPY than in KWD, and a per
currency floor needs a per currency number that nothing here can produce.

This is deliberately a different question from `account_risk_daily` in
`lakehouse-pipeline`, which flags an account day against a 30 day amount
baseline. That one asks how much. This one asks how fast, so it needs the
transaction and the one before it rather than a daily total.

## Tests

104 dbt tests, of which 4 run at warn severity rather than error.

The custom generic tests are in `tests/generic/` and are the ones worth
reading:

- **`reconciles_with`** compares a total in a mart against the same total in
  its parent, group by group, with a `FULL OUTER JOIN` so a group missing on
  one side fails too. This catches the failure nothing else here can see: an
  aggregate that is internally consistent, passes every uniqueness and range
  check, and is short because a join dropped rows. Uniqueness cannot see a
  row that is not there. Only the parent can. `fct_category_daily.total_amount`
  is tested against `fct_transactions.amount` this way.
- **`mutually_exclusive_flags`** asserts exactly one of a set of booleans is
  true. It uses `if(flag, 1, 0)` and never `cast(flag as int64)`, because
  `CAST(NULL AS INT64)` is null, the sum becomes null, `null != 1` evaluates
  to null, and the offending row is not returned. A null flag would pass the
  test whose only job is to catch it.
- **`monotonic_within_group`** asserts a column never decreases inside a
  partition, read in a given order.
- **`not_in_future`** takes a grace period, because clock skew on a client is
  normal and a timestamp three minutes into tomorrow is not worth an alert
  while one next March is.

Four tests are warn rather than error on purpose. `is_orphan_account` fires
when CRM has not created an account yet, `is_unknown_currency` when a currency
is missing from the seed, `channel` when a new payment channel appears, and
`tenure_days` when CRM holds an opening date in the future. Each of those is
something to go and read about. None of them is a reason to stop the load and
lose the day, and a pipeline that errors on them teaches people to disable
tests.

Every join to a dimension is a `LEFT` join and every miss becomes a flag. An
inner join on accounts is the quiet version of this bug: the opening
transaction of every new account disappears, the totals come out low, and
every test still passes.

## The offline gate

`dbt parse` builds the manifest. It resolves every ref, source, seed, macro
and test, and type-checks every config block, without opening a connection,
which is what makes the whole project checkable on a public runner.
`profiles.yml` is committed and credential-free for exactly that reason: the
`ci` target names a BigQuery project that exists only as a string.

`dbt compile` is the opposite. It asks the adapter for relation metadata and
needs real credentials, so it is not in CI.

CI also fails the build on deprecated dbt YAML. `dbt parse` accepts the old
forms and warns, which means a project can sit on them for a year and then
break all at once on an upgrade. The second parse step greps its own output
and exits non-zero if dbt reported anything deprecated.

### What the macro unit tests do and do not cover

`dbt parse` proves every macro exists, parses, and is called with arguments
that resolve. It says nothing about the SQL that comes out. `dbt compile`
would, and needs credentials.

`macro_tests/test_macros.py` fills that gap for the four macros and four
generic tests: it renders each one in a bare Jinja environment and asserts on
the text. The loader rewrites `{% test x %}` into `{% macro test_x %}` before
handing the file to Jinja, which is what dbt itself does, and `return()`
raises so that a macro returning a list returns a Python list here too.

That catches a flipped comparison, a dropped cast, a changed interval, an
argument that stopped being used, and the off-by-one between the two window
macros. It does not catch BigQuery rejecting the result. Nothing in the suite
opens a connection, reads a credential or needs a warehouse.

Four of the 38 are convention checks rather than macro tests, and they exist
because the conventions are load bearing: every macro file defines the macro
named after it, every generic test has a `WHERE` clause, and every
incremental model filters on the shared window and declares the partitions it
replaces. That last one guards the most expensive mistake available here, an
incremental model that reads the whole fact table every run and produces
perfectly correct numbers while doing it.

## Running it

```bash
python3.11 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"

dbt deps
dbt parse --target ci --profiles-dir .   # no credentials needed
pytest -q
ruff check macro_tests
```

Against a real warehouse, which needs a BigQuery project and a service
account:

```bash
export WM_BQ_PROJECT=your-project
export WM_BQ_DATASET=analytics
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json

dbt seed --target prod                   # 31 currencies, 38 mcc rows
dbt build --target prod                  # models then tests, in DAG order
dbt source freshness --target prod
```

`maximum_bytes_billed` is set on the `prod` target and not on `ci`. It is a
guard against a mistake rather than a budget: the fact table is partitioned by
`event_date`, and a query that forgets the partition filter should fail loudly
instead of succeeding slowly.

## Analyses

`analyses/` holds three queries dbt compiles and never runs. They are the
questions the marts exist to answer, and they stay analyses because each one
gets pasted into a console, argued with, and changed. Promoting
`review_queue.sql` to a model would mean a table whose definition is a work
queue's current opinion.

`baseline_coverage.sql` is the one to read first if you are about to build on
`amount_vs_trailing`. That column is null for a new account and null for a
dormant one, so a filter like `amount_vs_trailing > 2` silently drops both,
and the query counts what is being dropped by segment and tenure.

## What this does not do

- **No FX conversion**, as above. Cross-currency totals are absent rather than
  approximate.
- **No snapshots.** `dim_accounts` is a full rebuild because the CRM source is
  a current-state table with no change timestamps. A `dbt snapshot` over it
  would record the date dbt noticed a difference, not the date the account
  changed, which is worse than no history because it reads like history. If
  CRM starts emitting change events, `dim_accounts` becomes a view over a real
  snapshot.
- **No exposures and no semantic layer.** Nothing downstream is declared, so
  `dbt build` cannot tell you what a model change breaks.
- **No `dbt run` in CI.** Everything above is static validation. The models
  have never been executed against BigQuery in this repository, and the SQL
  was checked by parsing it with the BigQuery dialect rather than by running
  it. Dialect-valid is not the same as correct against real data, and the
  tests in `models/**/*.yml` are the part that only means something once a
  warehouse has run them.
