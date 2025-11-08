{{
    config(
        alias='voter_state_summary'
    )
}}

-- Mart: State-level voter analytics for reporting consumption.

with voters as (
    select * 
    from {{ ref('int_voters_cleaned') }}
    where not has_missing_data
),

state_metrics as (
    select
        state_code,
        count(*) as total_voters,

        avg(age) as avg_age,
        percentile_cont(0.5) within group (order by age) as median_age,

        sum(case when gender = 'M' then 1 else 0 end) as male_voters,
        sum(case when gender = 'F' then 1 else 0 end) as female_voters,

        sum(case when party = 'Democrat' then 1 else 0 end) as democrat_voters,
        sum(case when party = 'Republican' then 1 else 0 end) as republican_voters,
        sum(case when party = 'Independent' then 1 else 0 end) as independent_voters,

        sum(case when last_voted_date >= date '2024-01-01' then 1 else 0 end) as voters_2024,
        sum(
            case
                when last_voted_date >= date '2022-01-01'
                 and last_voted_date < date '2024-01-01' then 1
                else 0
            end
        ) as voters_2022,

        avg(case when is_valid_email then 1.0 else 0.0 end) as email_quality_rate

    from voters
    group by state_code
)

select 
    state_code,
    total_voters,
    round(avg_age, 1) as avg_age,
    median_age,
    male_voters,
    female_voters,
    round(100.0 * male_voters / nullif(total_voters, 0), 1) as male_pct,
    round(100.0 * female_voters / nullif(total_voters, 0), 1) as female_pct,
    democrat_voters,
    republican_voters,
    independent_voters,
    round(100.0 * democrat_voters / nullif(total_voters, 0), 1) as democrat_pct,
    round(100.0 * republican_voters / nullif(total_voters, 0), 1) as republican_pct,
    round(100.0 * independent_voters / nullif(total_voters, 0), 1) as independent_pct,
    voters_2024,
    voters_2022,
    round(100.0 * email_quality_rate, 1) as email_quality_pct
from state_metrics
order by total_voters desc
