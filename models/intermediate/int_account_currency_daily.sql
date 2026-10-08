-- Account, currency and day. The grain the money marts are built on.
--
-- Currency is part of the key and not an attribute. There is no FX rate
-- table anywhere in the medallion output, so this warehouse never converts
-- and never sums across currencies. An account that trades in EUR and GBP
-- gets two rows a day, and a dashboard that wants one number has to choose a
-- currency or choose a count. That is more work for whoever builds the
-- dashboard, and it is the only version of this table where every total is
-- true.
--
-- A view, not a table. Its one consumer is incremental and filters to a
-- window before reading, so materialising this would store a second copy of
-- an aggregate that is never queried directly. The tradeoff is that an
-- analyst who does query it directly scans the whole fact table and gets a
-- surprise, which is why the mart below it is the documented entry point.

select
    event_date,
    account_id,
    currency_code,

    count(*) as txn_count,
    count(distinct counterparty_id) as distinct_counterparties,
    count(distinct country_code) as distinct_countries,
    count(distinct mcc_category_group) as distinct_category_groups,

    {{ money('sum(amount)') }} as total_amount,
    {{ money('avg(amount)') }} as avg_amount,
    {{ money('max(amount)') }} as max_amount,
    sum(amount_minor) as total_amount_minor,

    countif(is_cross_border) as cross_border_count,
    countif(is_high_value) as high_value_count,
    -- Cash comes from the merchant category and not from the channel.
    -- Upstream channel is card, sepa, swift, wallet or unknown, and none of
    -- those says whether money left as cash. MCC 6011 does.
    countif(mcc_category_group = 'cash') as cash_count,

    min(occurred_at) as first_occurred_at,
    max(occurred_at) as last_occurred_at,
    any_value(segment) as segment

from {{ ref('fct_transactions') }}
group by event_date, account_id, currency_code
