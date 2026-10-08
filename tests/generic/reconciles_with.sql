{#
    A total in this model must equal the same total in a parent relation,
    group by group.

    This is the test that catches the failure mode nothing else here does: an
    aggregate that is internally consistent, passes every uniqueness and
    range check, and is short because a join dropped rows. Uniqueness cannot
    see a missing row. Only the parent can.

    FULL OUTER JOIN on purpose. An INNER JOIN compares the groups that exist
    on both sides and says nothing about a group that exists on one, which is
    exactly the case a dropped join key produces.

    The default tolerance is 0.0005, which is half of one minor unit of the
    finest currency in the seed, so it absorbs the rounding both sides do and
    still fails on a difference of a single unit of money.
#}
{% test reconciles_with(
    model,
    column_name,
    parent_relation,
    parent_column,
    group_by_columns,
    tolerance=0.0005
) %}

{%- if group_by_columns | length < 1 -%}
    {{ exceptions.raise_compiler_error(
        "reconciles_with() needs at least one group_by column"
    ) }}
{%- endif -%}

{%- set group_list = group_by_columns | join(', ') -%}

with model_side as (

    select
        {{ group_list }},
        sum({{ column_name }}) as side_total
    from {{ model }}
    group by {{ group_list }}

),

parent_side as (

    select
        {{ group_list }},
        sum({{ parent_column }}) as side_total
    from {{ parent_relation }}
    group by {{ group_list }}

)

select
    {%- for column in group_by_columns %}
    coalesce(m.{{ column }}, p.{{ column }}) as {{ column }},
    {%- endfor %}
    m.side_total as model_total,
    p.side_total as parent_total,
    abs(coalesce(m.side_total, 0) - coalesce(p.side_total, 0)) as difference
from model_side as m
full outer join parent_side as p
    on {% for column in group_by_columns -%}
    m.{{ column }} = p.{{ column }}{% if not loop.last %} and {% endif %}
    {%- endfor %}
where m.side_total is null
    or p.side_total is null
    or abs(m.side_total - p.side_total) > {{ tolerance }}

{% endtest %}
