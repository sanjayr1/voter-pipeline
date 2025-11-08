{{
    config(
        alias='voters_cleaned'
    )
}}

-- Intermediate layer applies type enforcement, standardization, and quality flags.

with staged as (
    select * from {{ ref('stg_voters') }}
),

standardized as (
    select
        voter_id,

        -- Names with defaults for missing values to expose data gaps downstream
        coalesce(first_name, 'UNKNOWN') as first_name,
        coalesce(last_name, 'UNKNOWN') as last_name,

        -- Age validation bounded by configured thresholds
        case 
            when age is null then null
            when age < {{ var('min_voter_age') }} then null
            when age > {{ var('max_voter_age') }} then null
            else age
        end as age,

        -- Invalid age flag for data quality reporting
        case
            when age is null then true
            when age < {{ var('min_voter_age') }} or age > {{ var('max_voter_age') }} then true
            else false
        end as has_invalid_age,

        -- Normalize gender to a predictable set
        case
            when gender in ('M', 'MALE') then 'M'
            when gender in ('F', 'FEMALE') then 'F'
            else 'U'
        end as gender,

        -- State standardization macro maps to USPS code when possible
        {{ standardize_state('state_raw') }} as state_code,
        state_raw,

        party,

        -- Email normalization + validation flag
        email,
        {{ validate_email('email') }} as is_valid_email,

        -- Flexible date parsing handles multiple source formats
        {{ parse_flexible_date('registered_date_raw') }} as registered_date,
        {{ parse_flexible_date('last_voted_date_raw') }} as last_voted_date,
        {{ parse_flexible_date('updated_at_raw') }} as updated_at,

        -- Composite missing-data flag
        case
            when first_name is null or last_name is null then true
            when age is null then true
            when {{ standardize_state('state_raw') }} is null then true
            else false
        end as has_missing_data,

        load_timestamp,
        source_file_hash,
        current_timestamp as processed_at

    from staged
)

select * from standardized
