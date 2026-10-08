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
-- single day, and the rapid-fire rule then fires on whichever rule treats
-- null as small. The final WHERE trims the extra day back off, so the model
-- writes exactly the partitions it declares.
--
-- The two rolling windows are deliberately not partitioned the same way.
-- txns_last_hour ignores currency, because a count is not money and six
-- transactions in an hour are six transactions whichever currencies they
-- were in. amount_last_24h partitions by currency as well, because summing
-- across currencies without an FX rate produces a number with no unit.

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

        -- Scoped to the account's day, not to the read window. See the note
        -- in the README about what the sliding version of this column did.
        row_number() over w_account_day as txn_seq_in_day,

        lag(occurred_at) over w_account as prev_occurred_at,
        timestamp_diff(
            occurred_at, lag(occurred_at) over w_account, second
        ) as seconds_since_prev,
        lag(country_code) over w_account as prev_country_code,

        count(*) over w_account_hour as txns_last_hour,
        {{ money('sum(amount) over w_account_currency_day') }} as amount_last_24h

    from window_input

    window
        -- occurred_at alone is not a total order. Two transactions in the
        -- same millisecond otherwise swap places between runs, and both the
        -- sequence number and the lag columns change without the data
        -- changing. transaction_id is the tiebreak that makes the ordering
        -- reproducible.
        w_account as (
            partition by account_id
            order by occurred_at, transaction_id
        ),
        w_account_day as (
            partition by account_id, event_date
            order by occurred_at, transaction_id
        ),
        -- RANGE and not ROWS, over unix_seconds, so the frame is a real hour
        -- of wall clock. ROWS 6 PRECEDING counts transactions regardless of
        -- how far apart they are, which for a quiet account reaches back
        -- weeks.
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
