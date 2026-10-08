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
        cluster_by=['account_id'],
    )
}}

-- Per account time ordering: the gap to the previous transaction, the country
-- it was in, and rolling counts. fct_velocity_alerts reads nothing else.
--
-- THIS MODEL READS ONE DAY MORE THAN IT WRITES, and the extra day is not
-- caution. A window function cannot see a row the WHERE clause already
-- removed. A transaction at 00:04 needs the one from 23:58 the night before
-- to know its own gap, so filtering the input to the write window makes
-- seconds_since_prev null for the first transaction of every account every
-- single day. The final WHERE trims the extra day back off.

{% set read_window = var('reprocess_window_days') + 1 %}

with window_input as (

    select
        transaction_id,
        account_id,
        event_date,
        occurred_at,
        amount,
        currency_code,
        country_code,
        channel,
        mcc_category_group
    from {{ ref('fct_transactions') }}

    {% if is_incremental() %}
    where {{ incremental_window('event_date', read_window) }}
    {% endif %}

),

sequenced as (

    select
        transaction_id,
        account_id,
        event_date,
        occurred_at,
        amount,
        currency_code,
        country_code,
        channel,
        mcc_category_group,

        row_number() over w_account as txn_seq,

        lag(occurred_at) over w_account as prev_occurred_at,
        timestamp_diff(
            occurred_at, lag(occurred_at) over w_account, second
        ) as seconds_since_prev,
        lag(country_code) over w_account as prev_country_code,

        count(*) over w_account_hour as txns_last_hour,
        {{ money('sum(amount) over w_account_currency_day') }} as amount_last_24h

    from window_input

    window
        w_account as (
            partition by account_id
            order by occurred_at, transaction_id
        ),
        w_account_hour as (
            partition by account_id
            order by unix_seconds(occurred_at)
            range between 3600 preceding and current row
        ),
        w_account_currency_day as (
            partition by account_id, currency_code
            order by unix_seconds(occurred_at)
            range between 86400 preceding and current row
        )

)

select * from sequenced

{% if is_incremental() %}
where {{ incremental_window('event_date') }}
{% endif %}
