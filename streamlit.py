import streamlit as st
from snowflake.snowpark.context import get_active_session
import altair as alt
import pandas as pd
from datetime import datetime, timedelta

session = get_active_session()

st.title("AI Pipeline Failure Investigator")
st.caption("Real-time failure detection | AI root cause analysis | Automated fix recommendations | CoCo AI Assistant")

@st.cache_data(ttl=60, show_spinner=False)
def load_failures(_session):
    return _session.sql("""
        SELECT EVENT_ID, SOURCE_TYPE, ERROR_MESSAGE, QUERY_TEXT,
               USER_NAME, WAREHOUSE_NAME, DATABASE_NAME, SCHEMA_NAME,
               START_TIME, PIPELINE_TYPE, ERROR_CATEGORY,
               ROOT_CAUSE, SEVERITY, SUGGESTED_FIX, FIX_SQL,
               CONFIDENCE_SCORE, STATUS
        FROM OPS_AI_MONITOR.AI_ENGINE.V_FAILURE_INSIGHTS_ENRICHED
        ORDER BY START_TIME DESC
    """).to_pandas()

@st.cache_data(ttl=60, show_spinner=False)
def load_kb(_session):
    return _session.sql("""
        SELECT PATTERN, ROOT_CAUSE, RECOMMENDED_FIX, FIX_SQL
        FROM OPS_AI_MONITOR.METADATA.ERROR_KB
        ORDER BY PATTERN
    """).to_pandas()

@st.cache_data(ttl=60, show_spinner=False)
def load_metrics(_session):
    return _session.sql("SELECT * FROM OPS_AI_MONITOR.AI_ENGINE.V_FAILURE_METRICS").to_pandas()

@st.cache_data(ttl=60, show_spinner=False)
def load_sla(_session):
    return _session.sql("SELECT * FROM OPS_AI_MONITOR.AI_ENGINE.V_SLA_BREACH").to_pandas()

@st.cache_data(ttl=60, show_spinner=False)
def load_sla_summary(_session):
    return _session.sql("SELECT * FROM OPS_AI_MONITOR.AI_ENGINE.V_SLA_SUMMARY").to_pandas()

@st.cache_data(ttl=60, show_spinner=False)
def load_alerts(_session):
    return _session.sql("""
        SELECT EVENT_ID, ALERT_FLAG, ISSUE_TYPE, PIPELINE_TYPE,
               SEVERITY, ERROR_MESSAGE, FAILURES_IN_WINDOW, START_TIME
        FROM OPS_AI_MONITOR.AI_ENGINE.V_CRITICAL_ALERTS
        ORDER BY ALERT_FLAG, START_TIME DESC LIMIT 50
    """).to_pandas()

@st.cache_data(ttl=60, show_spinner=False)
def load_custom_logs(_session):
    return _session.sql("""
        SELECT EVENT_ID, PIPELINE_NAME, SOURCE_SYSTEM, ERROR_MESSAGE,
               STATUS, DATABASE_NAME, SCHEMA_NAME, START_TIME
        FROM OPS_AI_MONITOR.EVENT_LOGS.CUSTOM_LOGS
        ORDER BY CREATED_AT DESC LIMIT 50
    """).to_pandas()

@st.cache_data(ttl=60, show_spinner=False)
def load_auto_fixes(_session):
    return _session.sql("""
        SELECT EVENT_ID, FIX_SQL, EXECUTION_STATUS, ERROR_MESSAGE, EXECUTED_AT
        FROM OPS_AI_MONITOR.AI_ENGINE.AUTO_FIX_LOGS
        ORDER BY EXECUTED_AT DESC LIMIT 20
    """).to_pandas()

@st.cache_data(ttl=300, show_spinner=False)
def backfill_missing_fixes(_session, event_ids_str):
    return _session.sql(f"""
        SELECT
            FE.EVENT_ID,
            SNOWFLAKE.CORTEX.COMPLETE(
                'mistral-large2',
                CONCAT(
                    'You are a Snowflake SQL expert. Given this error, provide ONLY an executable Snowflake SQL fix. ',
                    'If no SQL fix is possible, respond with: N/A\\n\\n',
                    'ERROR: ', LEFT(FE.ERROR_MESSAGE, 500), '\\n',
                    'QUERY: ', LEFT(COALESCE(FE.QUERY_TEXT, ''), 500), '\\n\\n',
                    'Return ONLY the SQL statement. No explanation.'
                )
            ) AS GENERATED_FIX
        FROM OPS_AI_MONITOR.EVENT_LOGS.FAILURE_EVENTS FE
        WHERE FE.EVENT_ID IN ({event_ids_str})
        LIMIT 5
    """).to_pandas()

with st.spinner("Loading data..."):
    df = load_failures(session)
    kb = load_kb(session)
    metrics = load_metrics(session)
    sla = load_sla(session)
    sla_summary = load_sla_summary(session)
    alerts = load_alerts(session)
    custom_logs = load_custom_logs(session)
    auto_fixes = load_auto_fixes(session)

if df.empty:
    st.success("No failures detected. All pipelines are healthy.")
    st.stop()

df["START_TIME"] = pd.to_datetime(df["START_TIME"])
df["TIMESTAMP"] = df["START_TIME"].dt.strftime("%Y-%m-%d %H:%M:%S")

st.subheader("Date range")
d1, d2 = st.columns(2)
min_date = df["START_TIME"].min().date()
max_date = df["START_TIME"].max().date()
with d1:
    start_date = st.date_input("From", value=min_date, min_value=min_date, max_value=max_date)
with d2:
    end_date = st.date_input("To", value=max_date, min_value=min_date, max_value=max_date)

df = df[(df["START_TIME"].dt.date >= start_date) & (df["START_TIME"].dt.date <= end_date)]

if df.empty:
    st.warning("No failures in selected date range.")
    st.stop()

tab1, tab2, tab3, tab4, tab5, tab6, tab7 = st.tabs([
    "Overview",
    "SLA & Performance",
    "Critical Alerts",
    "AI Analysis",
    "External Pipelines",
    "Knowledge Base",
    "CoCo AI"
])

with tab1:
    st.subheader("Filters")
    f1, f2, f3 = st.columns(3)
    with f1:
        sev_opts = sorted(df["SEVERITY"].dropna().unique().tolist())
        sev_filter = st.multiselect("Severity", sev_opts, default=sev_opts)
    with f2:
        pipe_opts = sorted(df["PIPELINE_TYPE"].dropna().unique().tolist())
        pipe_filter = st.multiselect("Pipeline type", pipe_opts, default=pipe_opts)
    with f3:
        cat_opts = sorted(df["ERROR_CATEGORY"].dropna().unique().tolist())
        cat_filter = st.multiselect("Error category", cat_opts, default=cat_opts)

    filtered = df[
        (df["SEVERITY"].isin(sev_filter)) &
        (df["PIPELINE_TYPE"].isin(pipe_filter)) &
        (df["ERROR_CATEGORY"].isin(cat_filter))
    ].sort_values("START_TIME", ascending=False)

    total = len(filtered)
    high = len(filtered[filtered["SEVERITY"] == "HIGH"])
    medium = len(filtered[filtered["SEVERITY"] == "MEDIUM"])
    analyzed = len(filtered[filtered["STATUS"] == "SUCCESS"])
    rate = (analyzed / total * 100) if total > 0 else 0
    no_fix = len(filtered[(filtered["FIX_SQL"].isna()) | (filtered["FIX_SQL"].astype(str).str.strip() == "") | (filtered["FIX_SQL"].astype(str) == "None")])
    ext_count = int(metrics["EXTERNAL_FAILURES"].iloc[0]) if not metrics.empty and "EXTERNAL_FAILURES" in metrics.columns else 0

    st.divider()

    m1, m2, m3, m4, m5, m6 = st.columns(6)
    m1.metric("Total", total)
    m2.metric("HIGH", high)
    m3.metric("MEDIUM", medium)
    m4.metric("AI Analyzed", analyzed)
    m5.metric("AI Rate", f"{rate:.0f}%")
    m6.metric("Missing Fix", no_fix)

    st.divider()

    c1, c2 = st.columns(2)
    with c1:
        st.subheader("By pipeline type")
        pipe_data = filtered.groupby("PIPELINE_TYPE").size().reset_index(name="COUNT")
        if not pipe_data.empty:
            chart1 = alt.Chart(pipe_data).mark_bar(
                cornerRadiusTopLeft=4, cornerRadiusTopRight=4
            ).encode(
                x=alt.X("PIPELINE_TYPE:N", title=None, sort="-y"),
                y=alt.Y("COUNT:Q", title="Failures"),
                color=alt.Color("PIPELINE_TYPE:N", legend=None)
            ).properties(height=280)
            st.altair_chart(chart1, use_container_width=True)

    with c2:
        st.subheader("By error category")
        cat_data = filtered.groupby("ERROR_CATEGORY").size().reset_index(name="COUNT")
        if not cat_data.empty:
            chart2 = alt.Chart(cat_data).mark_arc(innerRadius=50).encode(
                theta=alt.Theta("COUNT:Q"),
                color=alt.Color("ERROR_CATEGORY:N", title="Category"),
                tooltip=["ERROR_CATEGORY", "COUNT"]
            ).properties(height=280)
            st.altair_chart(chart2, use_container_width=True)

    st.divider()

    st.subheader("Failure timeline")
    timeline = filtered.copy()
    timeline["DATE"] = timeline["START_TIME"].dt.date
    time_data = timeline.groupby(["DATE", "SEVERITY"]).size().reset_index(name="COUNT")
    if not time_data.empty:
        chart3 = alt.Chart(time_data).mark_bar().encode(
            x=alt.X("DATE:T", title=None),
            y=alt.Y("COUNT:Q", title="Failures"),
            color=alt.Color("SEVERITY:N", scale=alt.Scale(
                domain=["HIGH", "MEDIUM", "LOW"],
                range=["#FF4B4B", "#FFA500", "#4CAF50"]
            ))
        ).properties(height=200)
        st.altair_chart(chart3, use_container_width=True)

    st.divider()

    st.subheader("Latest failures (sorted by time)")
    table_cols = ["TIMESTAMP", "SEVERITY", "PIPELINE_TYPE", "ERROR_CATEGORY",
                  "ROOT_CAUSE", "SUGGESTED_FIX", "FIX_SQL", "CONFIDENCE_SCORE", "STATUS"]
    display_df = filtered[table_cols].head(50).copy()
    display_df["FIX_SQL"] = display_df["FIX_SQL"].fillna("").astype(str).replace("None", "")
    display_df["SUGGESTED_FIX"] = display_df["SUGGESTED_FIX"].fillna("").astype(str).replace("None", "")
    display_df["ROOT_CAUSE"] = display_df["ROOT_CAUSE"].fillna("Pending").astype(str).replace("None", "Pending")
    st.dataframe(display_df.reset_index(drop=True), use_container_width=True)

    st.divider()

    st.subheader("Failure details with fixes")
    for _, row in filtered.head(20).iterrows():
        fix_sql = str(row["FIX_SQL"] or "")
        has_fix = fix_sql and fix_sql != "None" and fix_sql.strip()
        fix_icon = " [FIX]" if has_fix else " [NO FIX]"
        label = f"{row['TIMESTAMP']} | {row['SEVERITY']} | {row['PIPELINE_TYPE']} | {row['ERROR_CATEGORY']}{fix_icon}"

        with st.expander(label):
            e1, e2 = st.columns([1, 1])
            with e1:
                st.markdown("**Error**")
                st.code(str(row["ERROR_MESSAGE"] or "N/A")[:400], language=None)
                st.markdown("**Root cause**")
                rc = str(row["ROOT_CAUSE"] or "")
                if rc and rc != "None":
                    st.info(rc)
                else:
                    st.warning("Pending AI analysis")
            with e2:
                st.markdown("**Suggested fix**")
                sf = str(row["SUGGESTED_FIX"] or "")
                if sf and sf != "None":
                    st.success(sf)
                else:
                    st.warning("No fix suggestion yet")
                st.markdown("**Fix SQL**")
                if has_fix:
                    st.code(fix_sql, language="sql")
                else:
                    st.caption("No SQL fix available for this failure")
                st.caption(f"Confidence: {row['CONFIDENCE_SCORE'] if row['CONFIDENCE_SCORE'] else 'N/A'} | Source: {row['SOURCE_TYPE']}")

with tab2:
    st.subheader("SLA Summary by Pipeline")
    if not sla_summary.empty:
        s1, s2, s3 = st.columns(3)
        total_runs = int(sla_summary["TOTAL_RUNS"].sum())
        total_breached = int(sla_summary["BREACHED_RUNS"].sum())
        overall_rate = round((total_runs - total_breached) / max(total_runs, 1) * 100, 1)
        s1.metric("Total monitored runs", total_runs)
        s2.metric("SLA breaches", total_breached)
        s3.metric("SLA compliance", f"{overall_rate}%")
        st.divider()
        st.dataframe(sla_summary.reset_index(drop=True), use_container_width=True)
    else:
        st.info("No SLA data available yet.")

    st.divider()
    st.subheader("Execution time by pipeline")
    if not sla.empty:
        sla_chart = sla.copy()
        sla_chart["PIPELINE_TYPE"] = sla_chart["PIPELINE_TYPE"].fillna("UNKNOWN")
        perf_data = sla_chart.groupby("PIPELINE_TYPE").agg(
            AVG_TIME=("EXECUTION_TIME_SECONDS", "mean"),
            MAX_TIME=("EXECUTION_TIME_SECONDS", "max"),
            COUNT=("EVENT_ID", "count")
        ).reset_index()
        bar = alt.Chart(perf_data).mark_bar(
            cornerRadiusTopLeft=4, cornerRadiusTopRight=4
        ).encode(
            x=alt.X("PIPELINE_TYPE:N", title=None, sort="-y"),
            y=alt.Y("AVG_TIME:Q", title="Avg execution time (sec)"),
            color=alt.Color("PIPELINE_TYPE:N", legend=None),
            tooltip=["PIPELINE_TYPE", "AVG_TIME", "MAX_TIME", "COUNT"]
        ).properties(height=300)
        st.altair_chart(bar, use_container_width=True)

    st.divider()
    st.subheader("Execution time distribution")
    if not sla.empty and len(sla) > 1:
        scatter = alt.Chart(sla).mark_circle(size=60).encode(
            x=alt.X("PIPELINE_TYPE:N", title=None),
            y=alt.Y("EXECUTION_TIME_SECONDS:Q", title="Execution time (sec)"),
            color=alt.Color("SLA_STATUS:N", scale=alt.Scale(
                domain=["OK", "BREACHED"], range=["#4CAF50", "#FF4B4B"]
            )),
            tooltip=["PIPELINE_TYPE", "EXECUTION_TIME_SECONDS", "SLA_STATUS"]
        ).properties(height=250)
        st.altair_chart(scatter, use_container_width=True)

with tab3:
    st.subheader("Active critical alerts")
    if not alerts.empty:
        a1, a2, a3 = st.columns(3)
        a1.metric("P1 - Critical", len(alerts[alerts["ALERT_FLAG"] == "P1"]))
        a2.metric("P2 - Urgent", len(alerts[alerts["ALERT_FLAG"] == "P2"]))
        a3.metric("P3 - Warning", len(alerts[alerts["ALERT_FLAG"] == "P3"]))
        st.divider()
        for _, alert in alerts.head(15).iterrows():
            flag = alert["ALERT_FLAG"]
            ts = str(alert["START_TIME"])[:19]
            with st.expander(f"[{flag}] {alert['ISSUE_TYPE']} | {alert['PIPELINE_TYPE']} | {ts}"):
                st.markdown(f"**Severity:** {alert['SEVERITY']}")
                st.markdown(f"**Pipeline:** {alert['PIPELINE_TYPE']}")
                st.markdown(f"**Repeated failures in window:** {alert['FAILURES_IN_WINDOW']}")
                st.code(str(alert["ERROR_MESSAGE"] or "N/A")[:300], language=None)
    else:
        st.success("No critical alerts. All systems nominal.")

with tab4:
    st.subheader("AI analysis details")
    events = df[["EVENT_ID", "ERROR_CATEGORY", "SEVERITY", "PIPELINE_TYPE", "TIMESTAMP"]].drop_duplicates("EVENT_ID")
    event_labels = [
        f"{r['TIMESTAMP']} | {r['SEVERITY']} | {r['PIPELINE_TYPE']} | {r['ERROR_CATEGORY']}"
        for _, r in events.head(30).iterrows()
    ]
    event_ids = events["EVENT_ID"].head(30).tolist()

    if event_ids:
        selected_idx = st.selectbox("Select a failure event", range(len(event_labels)),
                                     format_func=lambda i: event_labels[i])
        selected_id = event_ids[selected_idx]
        row = df[df["EVENT_ID"] == selected_id].iloc[0]

        s1, s2 = st.columns([1, 1])
        with s1:
            st.markdown("**Error message**")
            st.code(str(row["ERROR_MESSAGE"] or "N/A")[:500], language=None)
            st.markdown("**AI root cause**")
            if row["ROOT_CAUSE"] and str(row["ROOT_CAUSE"]) != "None":
                st.info(str(row["ROOT_CAUSE"]))
            else:
                st.warning("Pending AI analysis")
            st.markdown("**Confidence**")
            score = row["CONFIDENCE_SCORE"]
            if score and score > 0:
                st.progress(min(float(score), 1.0))
                st.caption(f"{float(score)*100:.0f}%")
            else:
                st.caption("N/A")

        with s2:
            st.markdown("**Suggested fix**")
            if row["SUGGESTED_FIX"] and str(row["SUGGESTED_FIX"]) != "None":
                st.success(str(row["SUGGESTED_FIX"]))
            else:
                st.warning("Pending AI analysis")
            st.markdown("**Fix SQL**")
            fix = str(row["FIX_SQL"] or "")
            if fix and fix != "None" and fix.strip():
                st.code(fix, language="sql")
            else:
                st.caption("No SQL fix available")
            st.markdown("**Metadata**")
            st.text(f"Time:      {row['TIMESTAMP']}")
            st.text(f"Pipeline:  {row['PIPELINE_TYPE']}")
            st.text(f"Category:  {row['ERROR_CATEGORY']}")
            st.text(f"Source:    {row.get('SOURCE_TYPE', 'N/A')}")
            st.text(f"User:      {row.get('USER_NAME', 'N/A')}")
            st.text(f"Warehouse: {row.get('WAREHOUSE_NAME', 'N/A')}")
            st.text(f"Database:  {row.get('DATABASE_NAME', 'N/A')}")

        with st.expander("View full query text"):
            st.code(str(row["QUERY_TEXT"] or "N/A"), language="sql")

    st.divider()
    st.subheader("Auto-fix execution log")
    if not auto_fixes.empty:
        af1, af2 = st.columns(2)
        af1.metric("Fixes attempted", len(auto_fixes))
        af2.metric("Fixes succeeded", len(auto_fixes[auto_fixes["EXECUTION_STATUS"] == "SUCCESS"]))
        st.dataframe(auto_fixes.reset_index(drop=True), use_container_width=True)
    else:
        st.info("No auto-fixes executed yet.")

with tab5:
    st.subheader("External pipeline failures")
    if not custom_logs.empty:
        e1, e2, e3 = st.columns(3)
        e1.metric("Fivetran", len(custom_logs[custom_logs["SOURCE_SYSTEM"] == "FIVETRAN"]))
        e2.metric("dbt", len(custom_logs[custom_logs["SOURCE_SYSTEM"] == "DBT"]))
        e3.metric("Custom ETL", len(custom_logs[custom_logs["SOURCE_SYSTEM"] == "CUSTOM"]))
        st.divider()
        ext_sources = custom_logs["SOURCE_SYSTEM"].unique().tolist()
        source_filter = st.multiselect("Filter by source", ext_sources, default=ext_sources, key="ext_src")
        ext_filtered = custom_logs[custom_logs["SOURCE_SYSTEM"].isin(source_filter)]

        ext_chart = ext_filtered.groupby("SOURCE_SYSTEM").size().reset_index(name="COUNT")
        if not ext_chart.empty:
            ch = alt.Chart(ext_chart).mark_bar(
                cornerRadiusTopLeft=4, cornerRadiusTopRight=4
            ).encode(
                x=alt.X("SOURCE_SYSTEM:N", title=None, sort="-y"),
                y=alt.Y("COUNT:Q", title="Failures"),
                color=alt.Color("SOURCE_SYSTEM:N", legend=None)
            ).properties(height=200)
            st.altair_chart(ch, use_container_width=True)
        st.divider()
        for _, log in ext_filtered.head(10).iterrows():
            ts = str(log["START_TIME"])[:19]
            with st.expander(f"[{log['SOURCE_SYSTEM']}] {log['PIPELINE_NAME']} | {ts}"):
                st.markdown(f"**Database:** {log.get('DATABASE_NAME', 'N/A')}.{log.get('SCHEMA_NAME', 'N/A')}")
                st.code(str(log["ERROR_MESSAGE"] or "N/A"), language=None)
    else:
        st.info("No external pipeline logs.")

with tab6:
    st.subheader("Error knowledge base")
    st.caption(f"{len(kb)} patterns loaded")
    if not kb.empty:
        for _, pattern in kb.iterrows():
            with st.expander(f"Pattern: {pattern['PATTERN']}"):
                st.markdown(f"**Root cause:** {pattern['ROOT_CAUSE']}")
                st.markdown(f"**Recommended fix:** {pattern['RECOMMENDED_FIX']}")
                if pattern["FIX_SQL"]:
                    st.code(str(pattern["FIX_SQL"]), language="sql")
    else:
        st.info("No patterns in knowledge base yet.")

with tab7:
    st.subheader("CoCo - AI Pipeline Assistant")
    st.caption("Ask CoCo anything about your pipeline failures, root causes, fixes, SLA, and trends")

    if "coco_history" not in st.session_state:
        st.session_state.coco_history = []

    for entry in st.session_state.coco_history:
        st.markdown(f"**You:** {entry['question']}")
        st.markdown(f"**CoCo:** {entry['answer']}")
        st.markdown("---")

    prompt = st.text_input("Ask CoCo", placeholder="e.g. Why are Fivetran syncs failing? What should I fix first?", key="coco_input")

    if st.button("Ask CoCo") and prompt:
        summary = session.sql("""
            SELECT PIPELINE_TYPE, ERROR_CATEGORY, SEVERITY, COUNT(*) AS FAILURE_COUNT
            FROM OPS_AI_MONITOR.AI_ENGINE.V_FAILURE_INSIGHTS_ENRICHED
            GROUP BY PIPELINE_TYPE, ERROR_CATEGORY, SEVERITY
            ORDER BY FAILURE_COUNT DESC LIMIT 20
        """).to_pandas().to_string(index=False)

        recent = session.sql("""
            SELECT PIPELINE_TYPE, ERROR_MESSAGE, ROOT_CAUSE, SEVERITY, SUGGESTED_FIX, FIX_SQL
            FROM OPS_AI_MONITOR.AI_ENGINE.V_FAILURE_INSIGHTS_ENRICHED
            WHERE STATUS = 'SUCCESS' ORDER BY START_TIME DESC LIMIT 5
        """).to_pandas().to_string(index=False)

        sla_text = sla_summary.to_string(index=False) if not sla_summary.empty else "No SLA data"
        alert_text = alerts[["ALERT_FLAG", "ISSUE_TYPE", "PIPELINE_TYPE"]].head(10).to_string(index=False) if not alerts.empty else "No alerts"
        kb_text = kb.to_string(index=False) if not kb.empty else "No KB entries"
        fix_text = auto_fixes.head(5).to_string(index=False) if not auto_fixes.empty else "No auto-fixes yet"

        system_prompt = (
            "You are CoCo, an expert Snowflake pipeline operations AI assistant. "
            "You help engineers understand failures, find root causes, and fix issues fast. "
            "Be concise, friendly, and always provide actionable SQL when relevant.\n\n"
            f"FAILURE SUMMARY:\n{summary}\n\n"
            f"RECENT AI ANALYSES:\n{recent}\n\n"
            f"SLA SUMMARY:\n{sla_text}\n\n"
            f"ACTIVE ALERTS:\n{alert_text}\n\n"
            f"AUTO-FIX LOG:\n{fix_text}\n\n"
            f"KNOWLEDGE BASE:\n{kb_text}\n\n"
            f"USER QUESTION: {prompt}\n\n"
            "Rules:\n"
            "- Provide executable Snowflake SQL when the user asks for fixes\n"
            "- Reference specific data from the summaries above\n"
            "- Prioritize HIGH severity and P1/P2 alerts\n"
            "- Keep answers under 250 words\n"
            "- Sign off as CoCo"
        )

        with st.spinner("CoCo is thinking..."):
            response = session.sql(
                "SELECT SNOWFLAKE.CORTEX.COMPLETE('mistral-large2', ?) AS R",
                params=[system_prompt]
            ).collect()[0]["R"]

        st.session_state.coco_history.append({"question": prompt, "answer": response})
        st.markdown(f"**CoCo:** {response}")

