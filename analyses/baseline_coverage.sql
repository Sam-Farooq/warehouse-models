-- How much of the account population the trailing baseline actually covers.
--
-- Worth asking before anyone builds on amount_vs_trailing. That column is
-- null for a new account and null for a dormant one, and a dashboard that
-- filters `amount_vs_trailing > 2` silently drops both. This counts what is
-- being dropped, by segment and by tenure, so the answer is a number rather
-- than a shrug.

with recent as (

    select
        account_id,
        currency_code,
        event_date,
        has_usable_baseline,
        active_days_trailing,
        amount_vs_trailing,
        txn_count
    from {{ ref('fct_account_currency_daily') }}
    where event_date >= date_sub(current_date(), interval {{ var('trailing_window_days') }} day)
        and event_date < current_date()

),

accounts as (

    select
        account_id,
        segment,
        tenure_days,
        lifetime_txn_count,
        case
            when tenure_days < 30 then '00_under_30d'
            when tenure_days < 90 then '01_30_to_90d'
            when tenure_days < 365 then '02_90d_to_1y'
            else '03_over_1y'
        end as tenure_bucket
    from {{ ref('dim_accounts') }}

),

joined as (

    select
        a.segment,
        a.tenure_bucket,
        r.currency_code,
        r.account_id,
        r.event_date,
        r.has_usable_baseline,
        r.active_days_trailing,
        r.amount_vs_trailing
    from recent as r
    inner join accounts as a
        on r.account_id = a.account_id

)

select
    segment,
    tenure_bucket,
    currency_code,

    count(*) as account_days,
    count(distinct account_id) as accounts,

    countif(has_usable_baseline) as account_days_with_baseline,
    safe_divide(countif(has_usable_baseline), count(*)) as baseline_coverage,

    countif(amount_vs_trailing is null) as account_days_without_ratio,
    round(avg(active_days_trailing), 2) as mean_active_days_trailing,

    -- The median of a column that is null half the time, over the rows where
    -- it is not null, which is the only version of this number that means
    -- anything.
    round(
        approx_quantiles(amount_vs_trailing ignore nulls, 100)[offset(50)], 3
    ) as median_amount_vs_trailing

from joined
group by segment, tenure_bucket, currency_code
order by segment, tenure_bucket, currency_code
