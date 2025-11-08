{{
    config(
        alias='voter_engagement_metrics'
    )
}}

-- Voter engagement and participation patterns for civic targeting.

with voters as (
    select * from {{ ref('int_voters_cleaned') }}
),

engagement_calc as (
    select
        voter_id,
        state_code,
        party,
        age,
        gender,
        registered_date,
        last_voted_date,

        case
            when registered_date >= date '2024-01-01' then '2024_new'
            when registered_date >= date '2022-01-01' then '2022_2023'
            when registered_date >= date '2020-01-01' then '2020_2021'
            when registered_date >= date '2016-01-01' then '2016_2019'
            else 'pre_2016'
        end as registration_cohort,

        case
            when last_voted_date >= date '2024-01-01' then 'active_2024'
            when last_voted_date >= date '2022-01-01' then 'active_2022'
            when last_voted_date >= date '2020-01-01' then 'active_2020'
            when last_voted_date is null then 'never_voted'
            else 'inactive'
        end as voter_status,

        extract(year from current_date) - extract(year from registered_date) as years_registered,

        current_date - last_voted_date as days_since_last_vote

    from voters
)

select
    voter_status,
    registration_cohort,
    count(*) as voter_count,

    avg(age) as avg_age,
    sum(case when gender = 'M' then 1 else 0 end) as male_count,
    sum(case when gender = 'F' then 1 else 0 end) as female_count,

    sum(case when party = 'Democrat' then 1 else 0 end) as democrat_count,
    sum(case when party = 'Republican' then 1 else 0 end) as republican_count,
    sum(case when party = 'Independent' then 1 else 0 end) as independent_count,

    case
        when voter_status = 'active_2024' then 100
        when voter_status = 'active_2022' then 75
        when voter_status = 'active_2020' then 50
        when voter_status = 'never_voted' then 25
        else 10
    end as engagement_score

from engagement_calc
group by voter_status, registration_cohort
order by engagement_score desc, voter_count desc
