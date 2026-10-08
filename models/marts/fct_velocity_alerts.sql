{{
    config(
        materialized='incremental',
        incremental_strategy='insert_overwrite',
        partition_by={
            'field': 'event_date',
            'data_type': 'date',
            'granularity': 'day',
        },
        partitions=partition_window(),
        cluster_by=['alert_type', 'account_id'],
    )
}}

-- One row per transaction, carrying at most one velocity alert.
--
-- Time based, and that is the whole difference from account_risk_daily in
-- lakehouse-pipeline, which flags an account day against a 30 day amount
-- baseline. This one asks how fast, not how much, so it needs the
-- transaction and the one before it rather than a daily total.
--
-- The flags are priority ordered and mutually exclusive. A transaction that
-- satisfies two rules gets the first one in the CASE, which means a count of
-- rapid_fire rows is not a count of transactions that triggered the
-- rapid-fire rule. Independent boolean columns would keep both, at the price
-- of a row appearing in three dashboards and a total that double counts.
-- Exclusive is the version an analyst can sum, and the price is stated here
-- rather than discovered later.
--
-- The thresholds are in dbt_project.yml and they are conventions. Nothing in
-- this repo measured them, and any of them being right is a question for
-- whoever owns the alert queue.

with sequenced as (

    select * from {{ ref('int_transactions_sequenced') }}

    {% if is_incremental() %}
    where {{ incremental_window('event_date') }}
    {% endif %}

),

classified as (

    select
        transaction_id,
        account_id,
        event_date,
        occurred_at,
        amount,
        currency_code,
        country_code,
        prev_country_code,
        channel,
        mcc_category_group,
        txn_seq_in_day,
        seconds_since_prev,
        txns_last_hour,
        amount_last_24h,

        case
            when txns_last_hour >= {{ var('velocity_txn_per_hour') }}
                then 'rapid_fire'

            -- prev_country_code is null on the account's first ever
            -- transaction, and null is not a country change. Writing this as
            -- `country_code != prev_country_code` alone returns null rather
            -- than false, the CASE falls through, and the row quietly lands
            -- in whichever branch comes next.
            when prev_country_code is not null
                and country_code is not null
                and country_code != prev_country_code
                and seconds_since_prev is not null
                and seconds_since_prev <= {{ var('country_hop_seconds') }}
                then 'country_hop'

            -- An exact multiple of 1000 with no minor units, above a floor.
            -- The floor is in display units, so it means something different
            -- in JPY than in KWD. A per currency floor is the right fix and
            -- needs a per currency number that nothing here can produce, so
            -- the single floor is documented instead of hidden.
            when amount >= {{ var('round_amount_floor') }}
                and amount = trunc(amount)
                and mod(cast(amount as int64), 1000) = 0
                then 'round_amount'

            else 'none'
        end as alert_type

    from sequenced

)

select
    transaction_id,
    account_id,
    event_date,
    occurred_at,
    amount,
    currency_code,
    country_code,
    prev_country_code,
    channel,
    mcc_category_group,
    txn_seq_in_day,
    seconds_since_prev,
    txns_last_hour,
    amount_last_24h,

    alert_type,

    -- Derived from the one CASE above, so exactly one is true on every row
    -- by construction. The mutually_exclusive_flags test checks that the
    -- construction still holds, which is what breaks when somebody adds a
    -- fifth alert type and forgets one of these lines.
    alert_type = 'rapid_fire' as is_rapid_fire,
    alert_type = 'country_hop' as is_country_hop,
    alert_type = 'round_amount' as is_round_amount,
    alert_type = 'none' as is_normal,

    alert_type != 'none' as is_alert

from classified
