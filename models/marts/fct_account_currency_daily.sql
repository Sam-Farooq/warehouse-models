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
        cluster_by=['account_id', 'currency_code'],
    )
}}

-- Account day totals against their own trailing baseline.
--
-- This model reads 31 days and writes 3. The extra 28 are the baseline it
-- computes, not slack: a trailing average over a window the WHERE clause
-- truncated is an average over whatever survived, which on the first day of
-- a backfill is one row.

{% set trailing = var('trailing_window_days') %}
{% set read_window = trailing + var('reprocess_window_days') %}

with history as (

    select * from {{ ref('int_account_currency_daily') }}

    {% if is_incremental() %}
    where {{ incremental_window('event_date', read_window) }}
    {% endif %}

),

category_mix as (

    -- Herfindahl index over the day's category groups. 1.0 means every
    -- transaction that day was in one category, and 1/n means they were
    -- spread evenly over n. Same day only, so it needs the write window and
    -- not the trailing one.
    select
        event_date,
        account_id,
        currency_code,
        sum(pow(category_share, 2)) as category_hhi,
        count(*) as category_count
    from (
        select
            event_date,
            account_id,
            currency_code,
            mcc_category_group,
            safe_divide(
                count(*),
                sum(count(*)) over (
                    partition by event_date, account_id, currency_code
                )
            ) as category_share
        from {{ ref('fct_transactions') }}
        {% if is_incremental() %}
        where {{ incremental_window('event_date') }}
        {% endif %}
        group by event_date, account_id, currency_code, mcc_category_group
    )
    group by event_date, account_id, currency_code

),

windowed as (

    select
        event_date,
        account_id,
        currency_code,
        segment,

        txn_count,
        total_amount,
        avg_amount,
        max_amount,
        total_amount_minor,
        distinct_counterparties,
        distinct_countries,
        distinct_category_groups,
        cross_border_count,
        high_value_count,
        cash_count,
        first_occurred_at,
        last_occurred_at,

        -- RANGE over unix_date and not ROWS. ROWS 28 PRECEDING counts rows,
        -- and a row here only exists on a day the account transacted, so for
        -- an account that moves twice a month the ROWS version reaches back
        -- fourteen months and calls it a 28 day baseline. RANGE counts
        -- calendar days and simply has fewer rows in the frame.
        {{ money('avg(total_amount) over trailing_long') }} as avg_amount_trailing,
        {{ money('max(total_amount) over trailing_long') }} as max_amount_trailing,
        avg(txn_count) over trailing_long as avg_txn_count_trailing,
        count(*) over trailing_long as active_days_trailing,
        {{ money('sum(total_amount) over trailing_short') }} as amount_last_7d,
        count(*) over trailing_short as active_days_last_7d

    from history

    window
        trailing_long as (
            partition by account_id, currency_code
            order by unix_date(event_date)
            range between {{ trailing }} preceding and 1 preceding
        ),
        trailing_short as (
            partition by account_id, currency_code
            order by unix_date(event_date)
            range between 7 preceding and 1 preceding
        )

)

select
    w.event_date,
    w.account_id,
    w.currency_code,
    w.segment,

    w.txn_count,
    w.total_amount,
    w.avg_amount,
    w.max_amount,
    w.total_amount_minor,
    w.distinct_counterparties,
    w.distinct_countries,
    w.distinct_category_groups,
    w.cross_border_count,
    w.high_value_count,
    w.cash_count,
    w.first_occurred_at,
    w.last_occurred_at,

    w.avg_amount_trailing,
    w.max_amount_trailing,
    w.avg_txn_count_trailing,
    w.active_days_trailing,
    w.amount_last_7d,
    w.active_days_last_7d,

    -- safe_divide and an explicit nullif: a brand new account has a trailing
    -- average of null, and a dormant one can have a trailing average of 0.
    -- Both have to come out null rather than divide by zero or report an
    -- infinite ratio that a dashboard renders as a very tall bar.
    safe_divide(w.total_amount, nullif(w.avg_amount_trailing, 0)) as amount_vs_trailing,
    safe_divide(w.txn_count, nullif(w.avg_txn_count_trailing, 0)) as txn_count_vs_trailing,

    c.category_hhi,
    c.category_count,

    -- Below this, the trailing window has too few days to mean anything. The
    -- threshold is a convention, not a measurement: it is here so that a
    -- consumer filters on one named column instead of each team inventing
    -- its own minimum.
    w.active_days_trailing >= 7 as has_usable_baseline

from windowed as w
left join category_mix as c
    on w.event_date = c.event_date
    and w.account_id = c.account_id
    and w.currency_code = c.currency_code

{% if is_incremental() %}
where {{ incremental_window('w.event_date') }}
{% endif %}
