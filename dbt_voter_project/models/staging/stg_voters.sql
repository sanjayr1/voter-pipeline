{{
    config(
        alias='voters'
    )
}}

-- Staging: Basic type casting and whitespace cleanup while preserving source fidelity.
-- Downstream layers will handle business validation and enrichment.

with source as (
    select * from {{ source('raw', 'voters') }}
),

cleaned as (
    select
        -- Identifiers
        trim(id) as voter_id,

        -- Names (retain nulls to surface completeness issues downstream)
        trim(first_name) as first_name,
        trim(last_name) as last_name,

        -- Demographics
        try_cast(age as integer) as age,
        upper(trim(gender)) as gender,

        -- Geography (leave raw for mapping later)
        trim(state) as state_raw,

        -- Political
        trim(party) as party,

        -- Contact
        lower(trim(email)) as email,

        -- Dates stay raw; they come in multiple formats
        registered_date as registered_date_raw,
        last_voted_date as last_voted_date_raw,
        updated_at as updated_at_raw,

        -- Ingestion metadata
        load_timestamp,
        source_file_hash
    from source
    where id is not null
)

select * from cleaned
