{#
    Convert a decimal amount into the currency's own minor units.

    Needed because the only honest way to compare two amounts in different
    currencies without an FX rate is not to: there is no rate table in the
    medallion output, so nothing here converts. Minor units are for the
    opposite job, exact integer arithmetic within one currency, where a
    reconciliation that is out by a cent has to be out by exactly one unit
    rather than by 0.009999999.

    The explicit round() is not decoration. BigQuery's CAST to INT64 rounds
    half away from zero, which happens to be what is wanted here, but the
    behaviour is a property of the cast rather than of the intent, and
    somebody reading `cast(x * 100 as int64)` cannot tell whether the author
    knew that.
#}
{% macro to_minor_units(amount_expression, minor_units_expression) -%}
cast(round({{ amount_expression }} * pow(10, {{ minor_units_expression }})) as int64)
{%- endmacro %}
