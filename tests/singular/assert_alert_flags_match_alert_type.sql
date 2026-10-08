-- The boolean columns must agree with alert_type.
--
-- mutually_exclusive_flags checks that exactly one boolean is true. It does
-- not check that the true one is the right one: swapping is_rapid_fire and
-- is_country_hop passes that test and inverts every alert dashboard.

select
    transaction_id,
    alert_type,
    is_rapid_fire,
    is_country_hop,
    is_round_amount,
    is_normal,
    is_alert
from {{ ref('fct_velocity_alerts') }}
where is_rapid_fire != (alert_type = 'rapid_fire')
    or is_country_hop != (alert_type = 'country_hop')
    or is_round_amount != (alert_type = 'round_amount')
    or is_normal != (alert_type = 'none')
    or is_alert != (alert_type != 'none')
