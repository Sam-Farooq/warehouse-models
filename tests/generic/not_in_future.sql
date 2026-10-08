{#
    A date or timestamp column must not be ahead of today.

    grace_days exists because clock skew on a client is normal and a
    transaction stamped three minutes into tomorrow is not a bug worth waking
    anyone for, while one stamped next March is.

    Returns one row per offending value with a count, rather than every
    offending row. A failing test that prints 40 million rows is a test
    nobody reads twice.
#}
{% test not_in_future(model, column_name, grace_days=0) %}

select
    {{ column_name }} as offending_value,
    count(*) as rows_affected
from {{ model }}
where cast({{ column_name }} as date) > date_add(current_date(), interval {{ grace_days }} day)
group by 1

{% endtest %}
