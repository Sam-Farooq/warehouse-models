-- Seed passthrough. It exists so that no model refs a seed directly: when
-- the minor unit list moves from a CSV to a vendor feed, this is the only
-- file that changes.

select
    currency_code,
    iso_numeric,
    minor_units,
    currency_name

from {{ ref('currencies') }}
