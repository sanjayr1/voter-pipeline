{% macro validate_email(column_name) %}
    case
        when {{ column_name }} is null or trim({{ column_name }}) = '' then false
        when {{ column_name }} not like '%@%' then false
        when {{ column_name }} not like '%.%' then false
        when length({{ column_name }}) < 5 then false
        else true
    end
{% endmacro %}
