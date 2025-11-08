{% macro parse_flexible_date(column_name) %}
    case
        when {{ column_name }} is null or trim({{ column_name }}) = '' then null

        -- ISO date (YYYY-MM-DD)
        when {{ column_name }} ~ '^\d{4}-\d{2}-\d{2}$'
            then try_cast({{ column_name }} as date)

        -- ISO datetime (truncate to date)
        when {{ column_name }} ~ '^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}$'
            then try_cast(left({{ column_name }}, 10) as date)

        -- MM/DD/YYYY
        when {{ column_name }} ~ '^\d{1,2}/\d{1,2}/\d{4}$'
            then try_cast(strptime({{ column_name }}, '%m/%d/%Y') as date)

        -- MM/DD/YYYY HH:MM:SS
        when {{ column_name }} ~ '^\d{1,2}/\d{1,2}/\d{4} \d{1,2}:\d{2}:\d{2}$'
            then try_cast(
                strptime(split_part({{ column_name }}, ' ', 1), '%m/%d/%Y') as date
            )

        else null
    end
{% endmacro %}
