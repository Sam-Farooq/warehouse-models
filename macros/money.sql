{#
    Cast a money expression to NUMERIC with a fixed scale.

    Round first, then cast. The other order looks equivalent and is not:
    CAST(... AS NUMERIC) on a FLOAT64 keeps the full binary expansion, so
    0.145 stored as 0.14499999999999999 casts to 0.14499999999999999 and
    rounds to 0.14, while rounding the float first gives 0.15. One cent,
    multiplied by every transaction in a quarter.

    NUMERIC and not BIGNUMERIC: NUMERIC holds 38 digits with 9 after the
    point, which covers every amount this warehouse will see, and costs half
    the storage of BIGNUMERIC.
#}
{% macro money(expression, scale=2) -%}
cast(round({{ expression }}, {{ scale }}) as numeric)
{%- endmacro %}
