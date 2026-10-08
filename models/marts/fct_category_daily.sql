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
        cluster_by=['currency_code', 'mcc_category_group'],
    )
}}

-- Merchant category group by currency by day, with each group's share of its
-- own currency's day.
--
-- The share is computed inside the model rather than left to the consumer,
-- because the denominator is the part that gets it wrong: a BI tool
-- computing "percent of total" over a filtered view divides by the filtered
-- total, so filtering to three categories makes them sum to 100 percent.

with transactions as (

    select * from {{ ref('fct_transactions') }}

    {% if is_incremental() %}
    where {{ incremental_window('event_date') }}
    {% endif %}

),

aggregated as (

    select
        event_date,
        currency_code,
        mcc_category_group,

        count(*) as txn_count,
        count(distinct account_id) as active_accounts,
        count(distinct counterparty_id) as distinct_counterparties,

        {{ money('sum(amount)') }} as total_amount,
        {{ money('avg(amount)') }} as avg_amount,
        {{ money('max(amount)') }} as max_amount,

        -- approx_quantiles, and the name is the caveat: it reads a sketch
        -- rather than a sorted partition, so the answer is near the 95th
        -- percentile and not at it. percentile_cont is exact and sorts every
        -- row in the partition, which on the dining group of a busy day is
        -- the most expensive thing in this project. The approximation is
        -- what a trend line needs; anything that has to be defensible to the
        -- cent should go back to the fact table.
        {{ money('approx_quantiles(amount, 100)[offset(95)]') }} as p95_amount,
        {{ money('approx_quantiles(amount, 100)[offset(50)]') }} as median_amount,

        countif(is_cross_border) as cross_border_count,
        countif(is_high_value) as high_value_count,
        countif(is_unmapped_mcc) as unmapped_mcc_count

    from transactions
    group by event_date, currency_code, mcc_category_group

)

select
    event_date,
    currency_code,
    mcc_category_group,

    txn_count,
    active_accounts,
    distinct_counterparties,

    total_amount,
    avg_amount,
    max_amount,
    p95_amount,
    median_amount,

    cross_border_count,
    high_value_count,
    unmapped_mcc_count,

    safe_divide(
        total_amount,
        sum(total_amount) over (partition by event_date, currency_code)
    ) as share_of_currency_day_amount,
    safe_divide(
        txn_count,
        sum(txn_count) over (partition by event_date, currency_code)
    ) as share_of_currency_day_count

from aggregated
