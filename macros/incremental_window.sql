{#
    The WHERE clause every incremental model filters on.

    One definition, because three marts have to agree about the same span.
    The window counts calendar days inclusive of today, so days=3 means
    today, yesterday and the day before, and the predicate is therefore
    date_sub(current_date(), interval days - 1 day). The off-by-one is in one
    place instead of five.

    Keep this consistent with partition_window(): that macro lists the
    partitions insert_overwrite replaces, and if the filter covers four days
    while the list names three, the run reads a day it never writes. Nothing
    fails. The fourth day is simply read, aggregated and discarded, and the
    numbers look fine. macro_tests/test_macros.py asserts the two agree.
#}
{% macro incremental_window(date_column, days=none) -%}
    {%- set lookback = days if days is not none else var('reprocess_window_days') -%}
    {%- if lookback is not number or lookback < 1 -%}
        {{ exceptions.raise_compiler_error(
            "incremental_window() needs a lookback of at least 1 day, got " ~ lookback
        ) }}
    {%- endif -%}
{{ date_column }} >= date_sub(current_date(), interval {{ lookback - 1 }} day)
{%- endmacro %}
