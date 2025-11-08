{{
    config(
        alias='registration_trends'
    )
}}

-- Registration trends over time to illustrate voter growth patterns.

with voters as (
    select *
    from {{ ref('int_voters_cleaned') }}
    where registered_date is not null
),

monthly_registrations as (
    select
        date_trunc('month', registered_date) as registration_month,
        count(*) as new_registrations,

        sum(case when party = 'Democrat' then 1 else 0 end) as democrat_registrations,
        sum(case when party = 'Republican' then 1 else 0 end) as republican_registrations,
        sum(case when party = 'Independent' then 1 else 0 end) as independent_registrations,

        avg(age) as avg_age_at_registration

    from voters
    where registered_date >= date '2015-01-01'
    group by date_trunc('month', registered_date)
),

with_running_total as (
    select
        *,
        sum(new_registrations) over (order by registration_month) as cumulative_registrations,
        avg(new_registrations) over (
            order by registration_month 
            rows between 2 preceding and 2 following
        ) as moving_avg_registrations

    from monthly_registrations
)

select * from with_running_total
order by registration_month desc
