-- Account attributes, as CRM holds them right now.
--
-- closed_at is a timestamp upstream and becomes both a date and a boolean
-- here. The boolean is what every downstream filter actually wants, and
-- deriving it in five places is how two of them end up using >= and three
-- use >.

with source as (

    select * from {{ source('crm', 'accounts') }}

)

select
    account_id,
    customer_id,
    lower(segment) as segment,
    upper(home_country) as home_country_code,

    cast(opened_at as date) as opened_on,
    cast(closed_at as date) as closed_on,
    closed_at is not null as is_closed

from source
