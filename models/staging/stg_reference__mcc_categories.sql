-- Seed passthrough, same reason as the currency view.

select
    mcc,
    category,
    category_group

from {{ ref('mcc_categories') }}
