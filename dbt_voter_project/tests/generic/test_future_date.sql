-- Generic dbt test that fails when a date column is too far in the future.
{% test not_future_date(model, column_name, days_ahead=30) %}
    select *
    from {{ model }}
    where {{ column_name }} > current_date + interval {{ days_ahead }} day
{% endtest %}
