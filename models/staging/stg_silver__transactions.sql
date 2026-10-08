-- Rename, cast, normalise case. No filters and no business rules: when a mart
-- disagrees with the warehouse this file should never be a suspect.
--
-- Two things it does do, and both are here so that no mart has to remember
-- them. Money becomes NUMERIC, because a FLOAT64 sum over a day of payments
-- is not reproducible. Codes become uppercase, because silver carries
-- whatever the producing system sent and a join on currency fails silently
-- when one side is lowercase: the row survives, the dimension is null, and
-- the total is quietly short.

with source as (

    select * from {{ source('silver', 'transactions') }}

),

renamed as (

    select
        transaction_id,
        account_id,
        counterparty_id,

        {{ money('amount') }} as amount,
        upper(currency) as currency_code,
        upper(country) as country_code,
        lower(channel) as channel,
        mcc,

        occurred_at,
        event_date,
        is_high_value

    from source

)

select * from renamed
