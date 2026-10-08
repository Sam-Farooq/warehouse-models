{#
    A column must never decrease within a partition, read in a given order.

    Used on txn_seq_in_day, where the invariant is the whole point of the
    column: if it does not increase with occurred_at inside an account day,
    it is not a sequence and anything downstream that orders by it is wrong.

    strict=true rejects a repeat as well as a decrease, which is what a row
    number needs. A running total wants strict=false, because an amount of
    zero is allowed to leave it unchanged.
#}
{% test monotonic_within_group(model, column_name, partition_by, order_by, strict=true) %}

{%- set partition_list = partition_by | join(', ') -%}

with ordered as (

    select
        {{ partition_list }},
        {{ order_by }},
        {{ column_name }} as current_value,
        lag({{ column_name }}) over (
            partition by {{ partition_list }}
            order by {{ order_by }}
        ) as previous_value
    from {{ model }}

)

select *
from ordered
where previous_value is not null
    and current_value {% if strict %}<={% else %}<{% endif %} previous_value

{% endtest %}
