{{ config(materialized='ephemeral') }}

-- Transaction grain, widened with the three dimensions it needs.
--
-- Ephemeral, so it is inlined as a CTE into fct_transactions rather than
-- stored. It has exactly one consumer and no tests of its own, and
-- materialising it would mean a second copy of the fact table that nobody
-- queries and every backfill has to rebuild twice. The cost of the choice is
-- that the compiled fct_transactions is noticeably longer than the file you
-- read, and `dbt test` cannot point at this model directly, so the
-- assertions about these columns live on fct_transactions instead.
--
-- Every join is a LEFT join and every miss becomes a flag rather than a
-- dropped row. An inner join on accounts is the quiet version of this bug:
-- CRM creates an account a few minutes after the first transaction clears,
-- so an inner join silently loses the opening transaction of every new
-- account. The totals come out low, every test still passes, and the only
-- symptom is a number somebody has to notice.

with transactions as (

    select * from {{ ref('stg_silver__transactions') }}

),

accounts as (

    select * from {{ ref('stg_crm__accounts') }}

),

categories as (

    select * from {{ ref('stg_reference__mcc_categories') }}

),

currencies as (

    select * from {{ ref('stg_reference__currencies') }}

)

select
    t.transaction_id,
    t.account_id,
    t.counterparty_id,
    t.event_date,
    t.occurred_at,

    t.amount,
    t.currency_code,
    {{ to_minor_units('t.amount', 'c.minor_units') }} as amount_minor,
    c.minor_units,

    t.country_code,
    t.channel,
    t.mcc,
    coalesce(m.category, 'unmapped') as mcc_category,
    coalesce(m.category_group, 'unmapped') as mcc_category_group,

    a.customer_id,
    a.segment,
    a.home_country_code,
    a.opened_on,
    a.is_closed as is_closed_account,

    -- Negative for a transaction that cleared before CRM created the account,
    -- which is the ordering described above and is worth being able to count.
    date_diff(t.event_date, a.opened_on, day) as account_age_days,

    a.account_id is null as is_orphan_account,
    c.currency_code is null as is_unknown_currency,
    m.mcc is null as is_unmapped_mcc,

    t.country_code is not null
        and a.home_country_code is not null
        and t.country_code != a.home_country_code as is_cross_border,

    t.is_high_value

from transactions as t
left join accounts as a
    on t.account_id = a.account_id
left join categories as m
    on t.mcc = m.mcc
left join currencies as c
    on t.currency_code = c.currency_code
