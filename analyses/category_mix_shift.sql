-- Which merchant categories moved, week against week, inside one currency.
--
-- Shares and not amounts. A currency whose total volume doubled shows every
-- category up, and nothing in that tells you where the money went. The share
-- columns already sum to 1 inside a currency day, so the difference between
-- two weeks of shares is in percentage points and is comparable across
-- currencies that are nothing like the same size.

{% set recent_days = 7 %}
{% set compare_days = 14 %}

with daily as (

    select
        event_date,
        currency_code,
        mcc_category_group,
        txn_count,
        total_amount,
        active_accounts,
        share_of_currency_day_amount,
        p95_amount
    from {{ ref('fct_category_daily') }}
    where event_date >= date_sub(current_date(), interval {{ compare_days }} day)
        and event_date < current_date()

),

periods as (

    select
        currency_code,
        mcc_category_group,
        case
            when event_date >= date_sub(current_date(), interval {{ recent_days }} day)
                then 'recent'
            else 'prior'
        end as period,

        count(*) as days_observed,
        sum(txn_count) as txn_count,
        sum(total_amount) as total_amount,
        avg(share_of_currency_day_amount) as mean_share,
        avg(active_accounts) as mean_active_accounts,
        avg(p95_amount) as mean_p95_amount
    from daily
    group by currency_code, mcc_category_group, period

),

pivoted as (

    select
        currency_code,
        mcc_category_group,

        sum(if(period = 'recent', days_observed, 0)) as recent_days_observed,
        sum(if(period = 'prior', days_observed, 0)) as prior_days_observed,

        sum(if(period = 'recent', mean_share, 0)) as recent_mean_share,
        sum(if(period = 'prior', mean_share, 0)) as prior_mean_share,

        sum(if(period = 'recent', txn_count, 0)) as recent_txn_count,
        sum(if(period = 'prior', txn_count, 0)) as prior_txn_count,

        sum(if(period = 'recent', mean_p95_amount, 0)) as recent_mean_p95_amount,
        sum(if(period = 'prior', mean_p95_amount, 0)) as prior_mean_p95_amount
    from periods
    group by currency_code, mcc_category_group

)

select
    currency_code,
    mcc_category_group,

    recent_days_observed,
    prior_days_observed,

    round(recent_mean_share, 4) as recent_mean_share,
    round(prior_mean_share, 4) as prior_mean_share,
    round(recent_mean_share - prior_mean_share, 4) as share_change,

    recent_txn_count,
    prior_txn_count,
    safe_divide(recent_txn_count, nullif(prior_txn_count, 0)) as txn_count_ratio,

    round(recent_mean_p95_amount - prior_mean_p95_amount, 2) as p95_change,

    -- A category that was absent for most of one period has a mean share
    -- computed over a handful of days, and the comparison is noise. Both
    -- period lengths are reported so the reader can discount it, and the
    -- flag saves them doing the arithmetic.
    recent_days_observed < {{ recent_days }}
        or prior_days_observed < {{ compare_days - recent_days }} as is_sparse

from pivoted
order by abs(recent_mean_share - prior_mean_share) desc
