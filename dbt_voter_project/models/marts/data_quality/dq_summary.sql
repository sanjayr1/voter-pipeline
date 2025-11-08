-- Data quality summary for monitoring ingestion-to-mart integrity.

with source_counts as (
    select count(*) as raw_count from {{ source('raw', 'voters') }}
),

staged_counts as (
    select count(*) as staged_count from {{ ref('stg_voters') }}
),

cleaned_counts as (
    select 
        count(*) as cleaned_count,
        sum(case when has_missing_data then 1 else 0 end) as missing_data_count,
        sum(case when has_invalid_age then 1 else 0 end) as invalid_age_count,
        sum(case when not is_valid_email then 1 else 0 end) as invalid_email_count
    from {{ ref('int_voters_cleaned') }}
)

select
    raw_count,
    staged_count,
    cleaned_count,
    missing_data_count,
    invalid_age_count,
    invalid_email_count,
    round(
        100.0 * (cleaned_count - missing_data_count) / nullif(raw_count, 0),
        2
    ) as data_completeness_pct
from source_counts, staged_counts, cleaned_counts
