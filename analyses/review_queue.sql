-- The day's alert queue, in the order a reviewer should work it.
--
-- An analysis and not a model: dbt compiles it and never runs it, which is
-- the right shape for a query that gets pasted into a console, argued with,
-- and changed. Promoting it to a model would mean a table whose definition
-- is a work queue's current opinion.
--
-- The ordering is the only interesting part. Sorting by amount puts every
-- large ordinary payment at the top, which is how a reviewer learns to
-- ignore the queue. Sorting by how far the account is from its own baseline
-- puts the unusual first, and an account with no usable baseline sorts last
-- rather than first, because a null ratio is not evidence.

{% set review_date = "date_sub(current_date(), interval 1 day)" %}

with alerts as (

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
        alert_type,
        seconds_since_prev,
        txns_last_hour,
        amount_last_24h
    from {{ ref('fct_velocity_alerts') }}
    where event_date = {{ review_date }}
        and is_alert

),

context as (

    select
        event_date,
        account_id,
        currency_code,
        txn_count,
        total_amount,
        avg_amount_trailing,
        amount_vs_trailing,
        active_days_trailing,
        has_usable_baseline,
        category_hhi
    from {{ ref('fct_account_currency_daily') }}
    where event_date = {{ review_date }}

),

accounts as (

    select
        account_id,
        segment,
        home_country_code,
        tenure_days,
        lifetime_txn_count,
        distinct_countries
    from {{ ref('dim_accounts') }}

)

select
    a.alert_type,
    a.transaction_id,
    a.account_id,
    d.segment,
    d.tenure_days,
    d.lifetime_txn_count,

    a.occurred_at,
    a.amount,
    a.currency_code,
    a.country_code,
    a.prev_country_code,
    a.channel,
    a.mcc_category_group,

    a.seconds_since_prev,
    a.txns_last_hour,
    a.amount_last_24h,

    c.txn_count as account_txn_count_today,
    c.total_amount as account_total_today,
    c.avg_amount_trailing,
    c.amount_vs_trailing,
    c.active_days_trailing,
    c.category_hhi,

    -- An account below the baseline threshold is not low risk, it is
    -- unmeasured, and the two have to be told apart in the queue rather than
    -- in somebody's head.
    case
        when not c.has_usable_baseline then 'no_baseline'
        when c.amount_vs_trailing >= 5 then 'far_above_baseline'
        when c.amount_vs_trailing >= 2 then 'above_baseline'
        else 'within_baseline'
    end as baseline_bucket

from alerts as a
left join context as c
    on a.account_id = c.account_id
    and a.currency_code = c.currency_code
    and a.event_date = c.event_date
left join accounts as d
    on a.account_id = d.account_id

order by
    -- Nulls last, deliberately. BigQuery sorts nulls first on a descending
    -- order by default, which would put every unmeasured account at the top
    -- of the queue on the strength of having no evidence at all.
    c.has_usable_baseline desc,
    c.amount_vs_trailing desc nulls last,
    a.amount desc
