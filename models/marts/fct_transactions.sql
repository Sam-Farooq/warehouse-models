{{
    config(
        materialized='incremental',
        incremental_strategy='insert_overwrite',
        partition_by={
            'field': 'event_date',
            'data_type': 'date',
            'granularity': 'day',
            'copy_partitions': true,
        },
        partitions=partition_window(),
        cluster_by=['account_id', 'currency_code'],
        on_schema_change='append_new_columns',
    )
}}

-- The base fact. Everything else in marts/ reads this and not silver.
--
-- Why insert_overwrite and not merge, which is the dbt-bigquery default:
--
--   merge has to find the matching rows, and BigQuery has no index to find
--   them with. Without an incremental_predicates hint it scans the whole
--   target, so the cost of a run is a function of the table's history rather
--   than of the day being loaded. Two years in, loading today costs two
--   years.
--
--   insert_overwrite with a declared partition list rewrites exactly those
--   partitions. The cost is a function of the window, which is 3 days, and
--   stays that way for as long as the table lives. copy_partitions turns the
--   swap itself into a copy job rather than a query.
--
-- What that costs, stated plainly: the write is idempotent per partition and
-- not per row. If a transaction's event_date is ever corrected so that it
-- moves out of the replaced window, the old copy stays where it was and the
-- table has it twice. Silver deduplicates on transaction_id and derives
-- event_date from occurred_at, so dates do not drift in normal operation,
-- and a genuine correction is a full-refresh of the affected partitions
-- rather than something this model handles.

with enriched as (

    select * from {{ ref('int_transactions_enriched') }}

    {% if is_incremental() %}
    where {{ incremental_window('event_date') }}
    {% endif %}

)

select
    transaction_id,
    account_id,
    customer_id,
    counterparty_id,

    event_date,
    occurred_at,

    amount,
    amount_minor,
    currency_code,
    minor_units,

    country_code,
    home_country_code,
    channel,
    mcc,
    mcc_category,
    mcc_category_group,
    segment,

    account_age_days,
    is_cross_border,
    is_high_value,
    is_orphan_account,
    is_unknown_currency,
    is_unmapped_mcc,
    is_closed_account,

    -- A stable 0 to 99 bucket for sampling. farm_fingerprint is
    -- deterministic, so `where sample_bucket = 0` is the same one percent of
    -- transactions in every query and across every rebuild. rand() would
    -- give a different one percent each time, which makes two sampled
    -- numbers impossible to compare.
    mod(abs(farm_fingerprint(transaction_id)), 100) as sample_bucket,

    current_timestamp() as _modelled_at

from enriched
