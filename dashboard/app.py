"""
GoodParty Voter Analytics Dashboard
Interactive visualizations for voter registration and engagement data.
"""

from __future__ import annotations

import os
from pathlib import Path
from datetime import datetime
import shutil
import tempfile

import duckdb
import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
import streamlit as st

# ---------------------------------------------------------------------------
# Page + style configuration
# ---------------------------------------------------------------------------
st.set_page_config(
    page_title="GoodParty Voter Analytics",
    page_icon="🗳️",
    layout="wide",
    initial_sidebar_state="expanded",
)

st.markdown(
    """
    <style>
    .main-header {
        font-size: 3rem;
        color: #1f77b4;
        text-align: center;
        margin-bottom: 2rem;
    }
    .metric-card {
        background-color: #f0f2f6;
        padding: 1rem;
        border-radius: 0.5rem;
        text-align: center;
        box-shadow: 0 2px 4px rgba(0,0,0,0.08);
    }
    .stPlotlyChart {
        background-color: #ffffff;
        border-radius: 0.5rem;
        padding: 0.5rem;
        box-shadow: 0 2px 4px rgba(0,0,0,0.06);
    }
    </style>
    """,
    unsafe_allow_html=True,
)

# ---------------------------------------------------------------------------
# DuckDB helpers
# ---------------------------------------------------------------------------
DEFAULT_DB_PATH = "/usr/local/airflow/include/data/processed/goodparty.duckdb"
DUCKDB_PATH = os.getenv("DUCKDB_PATH", DEFAULT_DB_PATH)
DBT_MART_SCHEMA = os.getenv("DBT_MART_SCHEMA", "main_marts")
GENERATION_ORDER = ["gen_z", "millennial", "gen_x", "boomer", "silent"]
GENERATION_COLOR_MAP = {
    "gen_z": "#F9C74F",
    "millennial": "#43AA8B",
    "gen_x": "#4D908E",
    "boomer": "#577590",
    "silent": "#F94144",
}


def _qualified_relation(table_name: str, schema: str | None = None) -> str:
    """Return fully qualified table name for DuckDB queries."""
    return f"{schema or DBT_MART_SCHEMA}.{table_name}"


@st.cache_resource(show_spinner=False)
def get_connection() -> duckdb.DuckDBPyConnection:
    """Create a cached DuckDB connection, falling back to a snapshot if locked."""
    db_path = Path(DUCKDB_PATH)
    if not db_path.exists():
        st.error(f"DuckDB warehouse not found at `{db_path}`. Run the Airflow + dbt pipeline first.")
        st.stop()

    try:
        return duckdb.connect(database=str(db_path), read_only=True)
    except duckdb.IOException as exc:
        if "could not set lock" not in str(exc).lower():
            raise
        snapshot_path = _create_snapshot(db_path)
        return duckdb.connect(database=str(snapshot_path), read_only=True)


def _create_snapshot(db_path: Path) -> Path:
    """Copy the DuckDB file (and WAL file if present) to a temp directory."""
    snapshot_dir = Path(tempfile.mkdtemp(prefix="goodparty_duckdb_snapshot_"))
    snapshot_path = snapshot_dir / db_path.name
    shutil.copy2(db_path, snapshot_path)

    wal_path = db_path.with_suffix(db_path.suffix + ".wal")
    if wal_path.exists():
        shutil.copy2(wal_path, snapshot_path.with_suffix(snapshot_path.suffix + ".wal"))

    return snapshot_path


def _run_query(sql: str) -> pd.DataFrame:
    conn = get_connection()
    return conn.execute(sql).df()


# ---------------------------------------------------------------------------
# Cached data loaders
# ---------------------------------------------------------------------------
@st.cache_data(ttl=300, show_spinner=False)
def load_state_summary() -> pd.DataFrame:
    return _run_query(f"select * from {_qualified_relation('voter_state_summary')} order by total_voters desc")


@st.cache_data(ttl=300, show_spinner=False)
def load_party_distribution() -> pd.DataFrame:
    return _run_query(f"select * from {_qualified_relation('voter_party_distribution')}")


@st.cache_data(ttl=300, show_spinner=False)
def load_engagement_metrics() -> pd.DataFrame:
    return _run_query(f"select * from {_qualified_relation('voter_engagement_metrics')}")


@st.cache_data(ttl=300, show_spinner=False)
def load_demographic_crosstab() -> pd.DataFrame:
    return _run_query(f"select * from {_qualified_relation('demographic_crosstab')}")


@st.cache_data(ttl=300, show_spinner=False)
def load_registration_trends() -> pd.DataFrame:
    return _run_query(
        f"""
        select *
        from {_qualified_relation('registration_trends')}
        order by registration_month
        """
    )


@st.cache_data(ttl=300, show_spinner=False)
def load_data_quality() -> pd.DataFrame:
    return _run_query(f"select * from {_qualified_relation('dq_summary')}")


# ---------------------------------------------------------------------------
# Page routers
# ---------------------------------------------------------------------------
def main() -> None:
    st.markdown('<h1 class="main-header">🗳️ GoodParty Voter Analytics Dashboard</h1>', unsafe_allow_html=True)

    with st.sidebar:
        st.title("Navigation")
        page = st.radio(
            "Select View",
            [
                "📊 Overview",
                "🗺️ Geographic Analysis",
                "🎯 Demographics",
                "📈 Trends",
                "✅ Data Quality",
            ],
        )

        st.markdown("---")
        st.markdown("### About")
        st.info(
            "Interactive insights derived from the DuckDB marts generated via Airflow + dbt. "
            "Designed for GoodParty.org interview demos."
        )
        st.markdown("---")
        st.markdown(f"**Last Refresh:** {datetime.now().strftime('%Y-%m-%d %H:%M')}")

    if page == "📊 Overview":
        show_overview()
    elif page == "🗺️ Geographic Analysis":
        show_geographic()
    elif page == "🎯 Demographics":
        show_demographics()
    elif page == "📈 Trends":
        show_trends()
    elif page == "✅ Data Quality":
        show_data_quality()


# ---------------------------------------------------------------------------
# Individual page renderers
# ---------------------------------------------------------------------------
def show_overview() -> None:
    st.header("📊 Voter Registration Overview")

    party_data = load_party_distribution()
    engagement_data = load_engagement_metrics()
    state_data = load_state_summary()

    if party_data.empty or engagement_data.empty or state_data.empty:
        st.warning("No mart data available. Ensure dbt models have been executed.")
        return

    total_voters = party_data["total_voters"].sum()
    active_voters = engagement_data.loc[engagement_data["voter_status"] == "active_2024", "voter_count"].sum()
    states_covered = state_data["state_code"].nunique()
    avg_age = party_data["avg_age"].mean()

    col1, col2, col3, col4 = st.columns(4)
    col1.metric("Total Registered Voters", f"{total_voters:,}")
    col2.metric("Active 2024 Voters", f"{active_voters:,}", f"{(100 * active_voters / total_voters):.1f}%")
    col3.metric("States Represented", states_covered)
    col4.metric("Average Age", f"{avg_age:.1f}")

    st.markdown("---")
    col1, col2 = st.columns(2)

    with col1:
        st.subheader("Party Affiliation Distribution")
        fig = px.pie(
            party_data,
            values="total_voters",
            names="party",
            hole=0.45,
            color="party",
            color_discrete_map={
                "Democrat": "#2E86C1",
                "Republican": "#E74C3C",
                "Independent": "#95A5A6",
            },
        )
        fig.update_layout(height=400, legend_title="Party")
        st.plotly_chart(fig, use_container_width=True)

    with col2:
        st.subheader("Voter Engagement Status")
        engagement_summary = (
            engagement_data.groupby("voter_status", as_index=False)["voter_count"].sum().sort_values("voter_count", ascending=False)
        )
        fig = px.bar(
            engagement_summary,
            x="voter_status",
            y="voter_count",
            color="voter_status",
            color_discrete_map={
                "active_2024": "#2ECC71",
                "active_2022": "#F39C12",
                "active_2020": "#E67E22",
                "inactive": "#95A5A6",
                "never_voted": "#E74C3C",
            },
        )
        fig.update_layout(height=400, showlegend=False, xaxis_title="Engagement Status", yaxis_title="Voters")
        st.plotly_chart(fig, use_container_width=True)


def show_geographic() -> None:
    st.header("🗺️ Geographic Analysis")
    state_data = load_state_summary()
    if state_data.empty:
        st.warning("State summary mart is empty. Run dbt first.")
        return

    states = st.multiselect(
        "Filter States (leave blank for all)", options=sorted(state_data["state_code"].unique()), default=[]
    )
    if states:
        state_data = state_data[state_data["state_code"].isin(states)]

    top_states = state_data.nlargest(10, "total_voters")

    col1, col2 = st.columns(2)
    with col1:
        st.subheader("Top States by Voter Count")
        fig = px.bar(
            top_states,
            x="total_voters",
            y="state_code",
            orientation="h",
            text="total_voters",
            color_discrete_sequence=["#9C27B0"],
        )
        fig.update_traces(marker_line_color="#5e1b6d", marker_line_width=1.5, texttemplate="%{text:.0f}", textposition="outside")
        max_total = max(top_states["total_voters"].max(), 1)
        fig.update_layout(
            height=480,
            xaxis_title="Total Voters",
            yaxis_title="State",
            xaxis=dict(range=[0, max_total * 1.15]),
            plot_bgcolor="#f8f9fb",
            paper_bgcolor="#ffffff",
        )
        st.plotly_chart(fig, use_container_width=True)

    with col2:
        st.subheader("Party Distribution by State")
        fig = go.Figure()
        party_cols = [
            ("democrat_pct", "Democrat", "#2E86C1"),
            ("republican_pct", "Republican", "#E74C3C"),
            ("independent_pct", "Independent", "#95A5A6"),
        ]
        for column, label, color in party_cols:
            fig.add_trace(
                go.Bar(
                    name=label,
                    y=top_states["state_code"],
                    x=top_states[column],
                    orientation="h",
                    marker_color=color,
                )
            )
        fig.update_layout(
            barmode="stack",
            height=480,
            xaxis_title="Percent of Voters",
            yaxis_title="State",
            legend_title="Party",
        )
        st.plotly_chart(fig, use_container_width=True)

    st.subheader("State Details")
    display_cols = [
        "state_code",
        "total_voters",
        "avg_age",
        "democrat_pct",
        "republican_pct",
        "independent_pct",
        "email_quality_pct",
    ]
    formatted = state_data[display_cols].copy()
    st.dataframe(
        formatted.style.format(
            {
                "total_voters": "{:,.0f}",
                "avg_age": "{:.1f}",
                "democrat_pct": "{:.1f}%",
                "republican_pct": "{:.1f}%",
                "independent_pct": "{:.1f}%",
                "email_quality_pct": "{:.1f}%",
            }
        ),
        use_container_width=True,
    )


def show_demographics() -> None:
    st.header("🎯 Demographic Analysis")
    demo_data = load_demographic_crosstab()
    if demo_data.empty:
        st.warning("Demographic mart is unavailable.")
        return

    st.subheader("Voter Distribution by Generation")
    gen_data = (
        demo_data.groupby("generation", as_index=False)["voter_count"]
        .sum()
        .set_index("generation")
        .reindex(GENERATION_ORDER, fill_value=0)
        .reset_index()
    )
    gen_data["generation"] = pd.Categorical(gen_data["generation"], categories=GENERATION_ORDER, ordered=True)
    gen_data = gen_data.sort_values("generation")
    fig = px.bar(
        gen_data,
        x="generation",
        y="voter_count",
        color="generation",
        color_discrete_map=GENERATION_COLOR_MAP,
    )
    fig.update_layout(height=420, showlegend=False, xaxis_title="Generation", yaxis_title="Voters")
    st.plotly_chart(fig, use_container_width=True)

    col1, col2 = st.columns(2)
    with col1:
        st.subheader("Gender Distribution by Party")
        gender_party = demo_data.groupby(["party", "gender"], as_index=False)["voter_count"].sum()
        fig = px.bar(
            gender_party,
            x="party",
            y="voter_count",
            color="gender",
            barmode="group",
            color_discrete_map={"M": "#3498DB", "F": "#E91E63", "U": "#95A5A6"},
        )
        fig.update_layout(height=420, xaxis_title="Party", yaxis_title="Voters")
        st.plotly_chart(fig, use_container_width=True)

    with col2:
        st.subheader("Age Distribution by Party")
        party_age = demo_data.groupby(["party", "generation"], as_index=False)["voter_count"].sum()
        party_age["generation"] = pd.Categorical(party_age["generation"], categories=GENERATION_ORDER, ordered=True)
        party_age = party_age.sort_values(["party", "generation"])
        fig = px.bar(
            party_age,
            x="party",
            y="voter_count",
            color="generation",
            barmode="stack",
            category_orders={"generation": GENERATION_ORDER},
            color_discrete_map=GENERATION_COLOR_MAP,
        )
        fig.update_layout(height=420, xaxis_title="Party", yaxis_title="Voters", legend_title="Generation")
        st.plotly_chart(fig, use_container_width=True)


def show_trends() -> None:
    st.header("📈 Registration & Engagement Trends")
    trends = load_registration_trends()
    if trends.empty:
        st.warning("Registration trends mart is empty.")
        return

    col1, col2 = st.columns(2)
    with col1:
        start_date = st.date_input("Start Date", value=pd.to_datetime("2015-01-01"))
    with col2:
        end_date = st.date_input("End Date", value=pd.to_datetime("2024-12-31"))

    trends["registration_month"] = pd.to_datetime(trends["registration_month"])
    mask = (trends["registration_month"] >= pd.to_datetime(start_date)) & (
        trends["registration_month"] <= pd.to_datetime(end_date)
    )
    filtered = trends.loc[mask]
    if filtered.empty:
        st.info("No data in selected date range.")
        return

    st.subheader("Monthly Registration Trends (5-Month Moving Average)")
    fig = px.line(
        filtered,
        x="registration_month",
        y="moving_avg_registrations",
        labels={"moving_avg_registrations": "Registrations"},
        markers=True,
    )
    fig.update_traces(line=dict(width=3, color="#1f77b4"))
    fig.add_scatter(
        x=filtered["registration_month"],
        y=filtered["new_registrations"],
        mode="markers",
        name="Actual",
        opacity=0.3,
        marker=dict(size=8, color="#A5D8FF"),
    )
    fig.update_layout(
        height=420,
        legend_title=None,
        yaxis=dict(zeroline=True, zerolinecolor="#E0E0E0"),
    )
    st.plotly_chart(fig, use_container_width=True)

    st.subheader("Cumulative Registrations")
    fig = px.area(filtered, x="registration_month", y="cumulative_registrations", labels={"cumulative_registrations": "Cumulative"})
    fig.update_layout(height=420)
    st.plotly_chart(fig, use_container_width=True)

    st.subheader("Registration Trends by Party")
    party_cols = ["democrat_registrations", "republican_registrations", "independent_registrations"]
    party_trends = filtered[["registration_month"] + party_cols].melt(
        id_vars="registration_month", var_name="party", value_name="registrations"
    )
    party_trends["party"] = party_trends["party"].str.replace("_registrations", "")
    fig = px.line(
        party_trends,
        x="registration_month",
        y="registrations",
        color="party",
        color_discrete_map={
            "democrat": "#1f77b4",
            "republican": "#E74C3C",
            "independent": "#F1C40F",
        },
    )
    fig.update_traces(line=dict(width=2.5))
    fig.update_layout(height=420, legend_title="Party")
    st.plotly_chart(fig, use_container_width=True)


def show_data_quality() -> None:
    st.header("✅ Data Quality Dashboard")
    dq_data = load_data_quality()
    if dq_data.empty:
        st.warning("Data quality mart is empty.")
        return

    row = dq_data.iloc[0]
    raw_count = int(row["raw_count"])
    cleaned_count = int(row["cleaned_count"])
    missing_pct = 100 * row["missing_data_count"] / raw_count if raw_count else 0

    col1, col2, col3, col4 = st.columns(4)
    col1.metric("Raw Records", f"{raw_count:,}")
    col2.metric("Clean Records", f"{cleaned_count:,}")
    col3.metric(
        "Records With Missing Fields",
        f"{int(row['missing_data_count']):,}",
        f"{missing_pct:.1f}%",
        delta_color="inverse",
    )
    col4.metric("Data Completeness", f"{row['data_completeness_pct']:.1f}%")

    st.markdown("---")
    st.subheader("Data Quality Issue Breakdown")

    issues = pd.DataFrame(
        {
            "Issue Type": ["Missing Data", "Invalid Age", "Invalid Email"],
            "Count": [
                int(row["missing_data_count"]),
                int(row["invalid_age_count"]),
                int(row["invalid_email_count"]),
            ],
        }
    )
    issues["Percentage"] = issues["Count"] / raw_count * 100 if raw_count else 0

    col1, col2 = st.columns(2)
    with col1:
        fig = px.bar(
            issues,
            x="Issue Type",
            y="Count",
            color="Issue Type",
            color_discrete_sequence=px.colors.qualitative.Set3,
        )
        fig.update_layout(height=420, showlegend=False)
        st.plotly_chart(fig, use_container_width=True)

    with col2:
        fig = go.Figure(
            go.Indicator(
                mode="gauge+number+delta",
                value=row["data_completeness_pct"],
                title={"text": "Overall Data Quality Score"},
                delta={"reference": 95},
                gauge={
                    "axis": {"range": [0, 100]},
                    "bar": {"color": "#1f77b4"},
                    "steps": [
                        {"range": [0, 80], "color": "#f2f2f2"},
                        {"range": [80, 95], "color": "#d7ebf5"},
                        {"range": [95, 100], "color": "#b3e5c6"},
                    ],
                    "threshold": {"line": {"color": "red", "width": 4}, "value": 95},
                },
            )
        )
        fig.update_layout(height=420)
        st.plotly_chart(fig, use_container_width=True)

    st.subheader("📋 Recommendations")
    if missing_pct > 5:
        st.warning("Missing data exceeds 5%. Consider upstream enrichment.")
    if row["invalid_email_count"] > 50:
        st.info("Hundreds of invalid emails detected—run email hygiene routines.")
    if row["data_completeness_pct"] < 95:
        st.error("Data completeness is below the 95% target.")
    else:
        st.success("Data quality meets the target threshold. ✅")


if __name__ == "__main__":
    main()
