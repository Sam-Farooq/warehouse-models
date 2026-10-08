{#
    Exactly one of a set of boolean columns must be true on every row.

    if() and not cast(). CAST(NULL AS INT64) is NULL, so one null flag makes
    the whole sum null, NULL != 1 evaluates to NULL, and the row is not
    returned. A null flag would pass the test whose only job is to catch it.
    if(flag, 1, 0) maps null to 0, the sum comes out short, and the row
    fails.
#}
{% test mutually_exclusive_flags(model, flags) %}

{%- if flags | length < 2 -%}
    {{ exceptions.raise_compiler_error(
        "mutually_exclusive_flags() needs at least 2 flags, got " ~ (flags | length)
    ) }}
{%- endif -%}

select
    {{ flags | join(',\n    ') }},
    count(*) as rows_affected
from {{ model }}
where (
    {%- for flag in flags %}
    if({{ flag }}, 1, 0){% if not loop.last %} +{% endif %}
    {%- endfor %}
) != 1
group by {{ range(1, (flags | length) + 1) | join(', ') }}

{% endtest %}
