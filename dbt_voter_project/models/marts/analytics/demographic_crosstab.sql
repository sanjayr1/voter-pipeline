{{
    config(
        alias='demographic_crosstab'
    )
}}

-- Cross-tabulation of demographics for representation analysis.

with voters as (
    select *
    from {{ ref('int_voters_cleaned') }}
    where not has_missing_data
),

age_groups as (
    select
        voter_id,
        case
            when age between 18 and 24 then 'gen_z'
            when age between 25 and 40 then 'millennial'
            when age between 41 and 56 then 'gen_x'
            when age between 57 and 75 then 'boomer'
            when age > 75 then 'silent'
            else 'unknown'
        end as generation
    from voters
)

select
    v.gender,
    ag.generation,
    v.party,
    count(*) as voter_count,

    round(
        100.0 * sum(case when v.last_voted_date >= date '2024-01-01' then 1 else 0 end)
        / nullif(count(*), 0),
        1
    ) as participation_rate_2024,

    count(distinct v.state_code) as states_represented,

    mode() within group (order by v.state_code) as most_common_state

from voters v
join age_groups ag on v.voter_id = ag.voter_id
group by v.gender, ag.generation, v.party
having count(*) >= 5
order by generation, gender, party
