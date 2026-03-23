# AI Data Pipeline Failure Investigator using Snowflake CoCo

## Overview

Data pipelines often fail due to configuration issues, resource limits, dependency failures, or external system errors. Debugging these failures is manual, time-consuming, and impacts business-critical data.

This project provides an **AI-powered pipeline monitoring system** built using **Snowflake CoCo and Cortex**, which automatically detects failures, analyzes root causes, and suggests fixes in near real-time.

---

## Problem Statement

Modern data pipelines are distributed across multiple systems such as Snowflake, dbt, and Fivetran.

Challenges:

* Logs are scattered across systems
* Debugging is manual and slow
* Root cause is not easily identifiable

Impact:

* SLA breaches
* Delayed reporting
* Poor data reliability

---

## Solution

We built an **AI-driven pipeline failure investigator** that:

1. Captures failures from:

   * Snowflake Queries
   * Tasks
   * Dynamic Tables
   * Snowpipe
   * External tools (Fivetran, dbt)
   * Custom ETL logs

2. Uses **Snowflake Cortex (LLM)** to:

   * Identify root cause
   * Assign severity
   * Suggest fixes
   * Generate executable SQL fixes

3. Automates workflows using:

   * Snowflake Tasks (DAG)
   * Alerting system (email notifications)
   * Auto-fix logic (optional)

4. Provides insights via:

   * Streamlit Dashboard
   * CoCo AI Assistant

---

## Architecture


Flow:
Failure Sources → Unified Failure View → Failure Table → Cortex AI → Insights → Alerts → Dashboard

---

## Key Features

* Centralized failure monitoring
* AI-powered root cause analysis
* Knowledge base integration
* SLA tracking and breach detection
* Critical alerting (P1/P2/P3)
* External pipeline monitoring (Fivetran, dbt)
* Auto-fix suggestions with SQL
* Interactive dashboard
* CoCo AI assistant

---

## Tech Stack

* Snowflake
* Snowflake Cortex (LLM)
* Snowflake Tasks (automation)
* SQL
* Streamlit
* CoCo (AI prompt-based development)

---

## CoCo Usage (Important)

This entire system is built using **Snowflake CoCo prompts**.

We also implemented:

* Custom Skill (`SKILL.md`)
* Reference (`REFERENCE.md`)
* Knowledge base-driven AI prompting

This enables:

* Context-aware AI responses
* Reusable logic
* Faster development


---

## Setup Instructions

### 1. Snowflake Setup

Run the full deployment script:

```sql
-- Run this in Snowflake worksheet
code.sql
```

---

---

### 2. Verify System

```sql
SELECT * FROM OPS_AI_MONITOR.AI_ENGINE.V_FAILURE_METRICS;
```

---

### 3. Run Streamlit Dashboard

In Snowflake:

```sql
CREATE STREAMLIT ...
```

Or locally:

```bash
streamlit run streamlit.py
```

---

## Dashboard Features

Tabs:

* Overview (failures, filters, trends)
* SLA & Performance
* Critical Alerts
* AI Analysis
* External Pipelines
* Knowledge Base
* CoCo AI Assistant

---

## Example Queries

```sql
-- View failures
SELECT * FROM OPS_AI_MONITOR.EVENT_LOGS.FAILURE_EVENTS;

-- View AI results
SELECT * FROM OPS_AI_MONITOR.AI_ENGINE.ERROR_ANALYSIS;

-- SLA summary
SELECT * FROM OPS_AI_MONITOR.AI_ENGINE.V_SLA_SUMMARY;
```

---

## Business Impact

* Debugging time reduced from 30–60 minutes to < 2 minutes
* Faster incident resolution
* Reduced SLA breaches
* Improved data reliability
* Increased engineering productivity

---

## Future Enhancements

* Auto-remediation for critical failures
* Slack / Teams / PagerDuty integration
* Predictive failure detection (ML)
* Multi-cloud monitoring
* Advanced anomaly detection

---

---

## Notes

* External logs (Fivetran/dbt) are simulated for demo
* Cortex responses depend on prompt quality and model output
* Designed for scalability and production use

---

## Conclusion

This project transforms pipeline monitoring from a manual, reactive process into an automated, intelligent, AI-driven system using Snowflake CoCo.
