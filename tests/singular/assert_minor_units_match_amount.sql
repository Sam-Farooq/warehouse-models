-- amount_minor must be amount expressed in the currency's own minor units.
--
-- The to_minor_units() macro is unit tested against the SQL it generates,
-- which proves the text is right and proves nothing about the data. This is
-- the other half: the same arithmetic, written out by hand here, against
-- every row that has a known currency. The two have to agree.
--
-- Restricted to known currencies, because amount_minor is null for a
-- currency that is not in the seed and a null is not a mismatch.

select
    f.transaction_id,
    f.currency_code,
    f.amount,
    f.amount_minor,
    c.minor_units,
    cast(round(f.amount * pow(10, c.minor_units)) as int64) as expected_amount_minor
from {{ ref('fct_transactions') }} as f
inner join {{ ref('stg_reference__currencies') }} as c
    on f.currency_code = c.currency_code
where f.amount_minor != cast(round(f.amount * pow(10, c.minor_units)) as int64)
