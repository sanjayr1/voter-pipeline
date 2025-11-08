{{
    config(
        alias='voter_party_distribution'
    )
}}

-- Mart: Party affiliation analytics and demographics.

with voters as (
    select * from {{ ref('int_voters_cleaned') }}
),

party_metrics as (
    select
        party,
        count(*) as total_voters,

        avg(age) as avg_age,

        sum(case when age between 18 and 29 then 1 else 0 end) as age_18_29,
        sum(case when age between 30 and 44 then 1 else 0 end) as age_30_44,
        sum(case when age between 45 and 64 then 1 else 0 end) as age_45_64,
        sum(case when age >= 65 then 1 else 0 end) as age_65_plus,

        sum(case when last_voted_date >= date '2024-01-01' then 1 else 0 end) as active_voters_2024,

        sum(case when registered_date >= date '2020-01-01' then 1 else 0 end) as new_registrations_since_2020

    from voters
    group by party
)

select * from party_metrics
order by total_voters desc
