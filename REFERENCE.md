# CoCo Reference Guide

## Error Patterns & Fix Templates

### MISSING_OBJECT
Error patterns: "does not exist", "unknown", "not found"
Diagnostic: `SHOW TABLES LIKE '%<object>%' IN ACCOUNT;`
Fix: `CREATE TABLE <table_name> (...);` or correct the object reference

### PERMISSION
Error patterns: "not authorized", "insufficient privileges", "access denied"
Diagnostic: `SHOW GRANTS TO ROLE <current_role>;`
Fix: `GRANT SELECT ON TABLE <db>.<schema>.<table> TO ROLE <role>;`

### SYNTAX
Error patterns: "syntax error", "compilation error", "unexpected"
Fix: Review and correct the SQL statement

### RUNTIME
Error patterns: "division by zero", "numeric overflow", "null value"
Fix: `SELECT col1 / NULLIF(col2, 0) FROM ...;`

### STALENESS
Error patterns: "stale stream", "stream has been recreated"
Diagnostic: `SHOW STREAMS LIKE '%<stream>%' IN ACCOUNT;`
Fix: Recreate the stream on the source table

### DATA_LOAD
Error patterns: "file format", "copy into failed", "field delimiter"
Fix: Verify file format options match the source file

### DEPENDENCY
Error patterns: "depends on", "source not found", "upstream missing"
Fix: Ensure all dependencies exist before running the pipeline

### CONNECTIVITY
Error patterns: "connection refused", "SSL", "timeout", "rate limit"
Fix: Check network policies, credentials, and external service availability

### SCHEMA_DRIFT
Error patterns: "column not found", "invalid identifier", "type mismatch"
Diagnostic: `DESCRIBE TABLE <table>;`
Fix: Align column names/types between source and target

### WAREHOUSE
Error patterns: "warehouse suspended", "warehouse not found", "resource limit"
Diagnostic: `SHOW WAREHOUSES;`
Fix: `ALTER WAREHOUSE <wh> RESUME;`

## Quick Analytical Queries

### Count by source type
```sql
SELECT SOURCE_TYPE, COUNT(*) AS cnt
FROM OPS_AI_MONITOR.AI_ENGINE.V_FAILURE_INSIGHTS_ENRICHED
GROUP BY SOURCE_TYPE ORDER BY cnt DESC;
```

### Count by pipeline type and severity
```sql
SELECT PIPELINE_TYPE, SEVERITY, COUNT(*) AS cnt
FROM OPS_AI_MONITOR.AI_ENGINE.V_FAILURE_INSIGHTS_ENRICHED
GROUP BY PIPELINE_TYPE, SEVERITY ORDER BY cnt DESC;
```

### Recent failures (last 1 hour)
```sql
SELECT EVENT_ID, SOURCE_TYPE, ERROR_MESSAGE, START_TIME
FROM OPS_AI_MONITOR.EVENT_LOGS.FAILURE_EVENTS
WHERE START_TIME >= DATEADD('HOUR', -1, CURRENT_TIMESTAMP())
ORDER BY START_TIME DESC LIMIT 20;
```

### Top root causes
```sql
SELECT ROOT_CAUSE, SEVERITY, COUNT(*) AS cnt
FROM OPS_AI_MONITOR.AI_ENGINE.ERROR_ANALYSIS
GROUP BY ROOT_CAUSE, SEVERITY ORDER BY cnt DESC LIMIT 10;
```

### Unanalyzed backlog
```sql
SELECT COUNT(*) AS pending_analysis
FROM OPS_AI_MONITOR.AI_ENGINE.V_AI_QUEUE;
```

### SLA breach summary
```sql
SELECT * FROM OPS_AI_MONITOR.AI_ENGINE.V_SLA_SUMMARY;
```

### Full system KPIs
```sql
SELECT * FROM OPS_AI_MONITOR.AI_ENGINE.V_FAILURE_METRICS;
```


