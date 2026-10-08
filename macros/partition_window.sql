{#
    The list of partitions a static insert_overwrite run replaces.

    dbt-bigquery has two ways to do insert_overwrite. Dynamic writes the
    results to a temporary table, queries it to discover which partitions were
    touched, and then overwrites those. Static takes the list up front and
    skips the discovery query entirely, which also makes the write eligible
    for copy_partitions, where the partition swap is a copy job rather than a
    query.

    Static needs this list to be known at compile time, which it is: the
    window is a project variable, not a property of the data.

    Returns a list of SQL date expressions, newest first.
#}
{% macro partition_window(days=none) -%}
    {%- set lookback = days if days is not none else var('reprocess_window_days') -%}
    {%- if lookback is not number or lookback < 1 -%}
        {{ exceptions.raise_compiler_error(
            "partition_window() needs a lookback of at least 1 day, got " ~ lookback
        ) }}
    {%- endif -%}
    {%- set partitions = [] -%}
    {%- for offset in range(lookback) -%}
        {%- if offset == 0 -%}
            {%- do partitions.append("current_date()") -%}
        {%- else -%}
            {%- do partitions.append("date_sub(current_date(), interval " ~ offset ~ " day)") -%}
        {%- endif -%}
    {%- endfor -%}
    {%- do return(partitions) -%}
{%- endmacro %}
