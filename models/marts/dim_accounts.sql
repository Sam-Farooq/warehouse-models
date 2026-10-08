{{ config(materialized='table') }}

-- One row per account, with CRM attributes and lifetime activity.
--
-- A full rebuild on every run, and not a snapshot. The CRM source is a
-- current state table with no change timestamps, so `dbt snapshot` here would
-- record the date dbt first noticed a difference, which is not the date the
-- account changed. That is worse than having no history, because it reads
-- like history and gets used like history. If CRM starts emitting change
-- events this model becomes a view over a real snapshot, and until then the
-- table honestly holds today only.
--
-- The rebuild is cheap because the fact table is clustered on account_id, so
-- the three aggregates below are cluster-local rather than full scans.

with accounts as (

    select * from {{ ref('stg_crm__accounts') }}

),

activity as (

    select
        account_id,
        count(*) as lifetime_txn_count,
        min(event_date) as first_txn_date,
        max(event_date) as last_txn_date,
        count(distinct currency_code) as distinct_currencies,
        count(distinct country_code) as distinct_countries,
        count(distinct mcc_category_group) as distinct_category_groups,
        countif(is_cross_border) as lifetime_cross_border_count
    from {{ ref('fct_transactions') }}
    group by account_id

),

primary_currency as (

    -- The currency the account uses most, with the code itself as the
    -- tiebreak so that an account split exactly between two currencies does
    -- not change its primary currency every time the table is rebuilt.
    select
        account_id,
        currency_code as primary_currency_code,
        currency_txn_count as primary_currency_txn_count
    from (
        select
            account_id,
            currency_code,
            count(*) as currency_txn_count,
            row_number() over (
                partition by account_id
                order by count(*) desc, currency_code
            ) as currency_rank
        from {{ ref('fct_transactions') }}
        group by account_id, currency_code
    )
    where currency_rank = 1

)

select
    a.account_id,
    a.customer_id,
    a.segment,
    a.home_country_code,
    a.opened_on,
    a.closed_on,
    a.is_closed,

    coalesce(act.lifetime_txn_count, 0) as lifetime_txn_count,
    act.first_txn_date,
    act.last_txn_date,
    coalesce(act.distinct_currencies, 0) as distinct_currencies,
    coalesce(act.distinct_countries, 0) as distinct_countries,
    coalesce(act.distinct_category_groups, 0) as distinct_category_groups,
    coalesce(act.lifetime_cross_border_count, 0) as lifetime_cross_border_count,

    pc.primary_currency_code,
    pc.primary_currency_txn_count,

    date_diff(current_date(), a.opened_on, day) as tenure_days,
    date_diff(current_date(), act.last_txn_date, day) as days_since_last_txn,

    -- Distinct from is_closed. An account can be open and silent, which is a
    -- different conversation from one that was closed.
    act.account_id is null as has_never_transacted,

    current_date() as _rebuilt_on

from accounts as a
left join activity as act
    on a.account_id = act.account_id
left join primary_currency as pc
    on a.account_id = pc.account_id
