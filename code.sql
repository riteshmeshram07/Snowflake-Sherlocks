-- ============================================================================
-- AI PIPELINE FAILURE INVESTIGATOR
-- Complete deployment script for OPS_AI_MONITOR
-- ============================================================================

-- ============================================================================
-- SECTION 1: INFRASTRUCTURE
-- ============================================================================

USE ROLE ACCOUNTADMIN;

CREATE DATABASE IF NOT EXISTS OPS_AI_MONITOR
    DATA_RETENTION_TIME_IN_DAYS = 14
    COMMENT = 'AI-powered pipeline failure monitoring system';

CREATE SCHEMA IF NOT EXISTS OPS_AI_MONITOR.EVENT_LOGS
    COMMENT = 'Raw failure events from queries, tasks, and system sources';

CREATE SCHEMA IF NOT EXISTS OPS_AI_MONITOR.AI_ENGINE
    COMMENT = 'Cortex AI enrichment outputs and classified failure insights';

CREATE SCHEMA IF NOT EXISTS OPS_AI_MONITOR.METADATA
    COMMENT = 'Reference and configuration tables for the monitoring pipeline';

CREATE SCHEMA IF NOT EXISTS OPS_AI_MONITOR.DEMO_ERRORS
    COMMENT = 'Schema for demo error generation across all pipeline types';

CREATE WAREHOUSE IF NOT EXISTS OPS_MONITOR_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Dedicated warehouse for pipeline failure monitoring workloads';

GRANT USAGE ON DATABASE OPS_AI_MONITOR TO ROLE SYSADMIN;
GRANT USAGE ON SCHEMA OPS_AI_MONITOR.EVENT_LOGS TO ROLE SYSADMIN;
GRANT USAGE ON SCHEMA OPS_AI_MONITOR.AI_ENGINE TO ROLE SYSADMIN;
GRANT USAGE ON SCHEMA OPS_AI_MONITOR.METADATA TO ROLE SYSADMIN;
GRANT USAGE ON WAREHOUSE OPS_MONITOR_WH TO ROLE SYSADMIN;

CREATE NOTIFICATION INTEGRATION IF NOT EXISTS OPS_ALERT_EMAIL
    TYPE = EMAIL
    ENABLED = TRUE;

-- ============================================================================
-- SECTION 2: TABLES
-- ============================================================================

CREATE OR REPLACE TABLE OPS_AI_MONITOR.EVENT_LOGS.FAILURE_EVENTS (
    EVENT_ID       VARCHAR(256)  NOT NULL,
    SOURCE_TYPE    VARCHAR(50)   NOT NULL,
    ERROR_MESSAGE  VARCHAR(16777216),
    QUERY_TEXT     VARCHAR(16777216),
    USER_NAME      VARCHAR(256),
    WAREHOUSE_NAME VARCHAR(256),
    DATABASE_NAME  VARCHAR(256),
    SCHEMA_NAME    VARCHAR(256),
    START_TIME     TIMESTAMP_LTZ NOT NULL,
    CREATED_AT     TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_FAILURE_EVENTS PRIMARY KEY (EVENT_ID, SOURCE_TYPE)
)
CLUSTER BY (START_TIME::DATE, SOURCE_TYPE)
DATA_RETENTION_TIME_IN_DAYS = 14
CHANGE_TRACKING = TRUE
COMMENT = 'Persisted failure events from all monitored sources';

CREATE OR REPLACE TABLE OPS_AI_MONITOR.EVENT_LOGS.STALE_STREAMS (
    STREAM_NAME     VARCHAR(512) NOT NULL,
    DATABASE_NAME   VARCHAR(256),
    SCHEMA_NAME     VARCHAR(256),
    STALE_SINCE     TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    DETECTED_AT     TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_STALE_STREAMS PRIMARY KEY (STREAM_NAME)
)
COMMENT = 'Tracks stale streams detected during monitoring sweeps';

CREATE OR REPLACE TABLE OPS_AI_MONITOR.EVENT_LOGS.CUSTOM_LOGS (
    EVENT_ID       VARCHAR(256)     NOT NULL DEFAULT UUID_STRING(),
    PIPELINE_NAME  VARCHAR(512)     NOT NULL,
    SOURCE_SYSTEM  VARCHAR(50)      NOT NULL,
    ERROR_MESSAGE  VARCHAR(16777216),
    QUERY_TEXT     VARCHAR(16777216),
    STATUS         VARCHAR(20)      NOT NULL DEFAULT 'FAILED',
    USER_NAME      VARCHAR(256),
    WAREHOUSE_NAME VARCHAR(256),
    DATABASE_NAME  VARCHAR(256),
    SCHEMA_NAME    VARCHAR(256),
    START_TIME     TIMESTAMP_LTZ    NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CREATED_AT     TIMESTAMP_LTZ    NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_CUSTOM_LOGS PRIMARY KEY (EVENT_ID)
)
CHANGE_TRACKING = TRUE
COMMENT = 'External pipeline failure logs from Fivetran, dbt, custom ETL systems';

CREATE OR REPLACE TABLE OPS_AI_MONITOR.AI_ENGINE.ERROR_ANALYSIS (
    EVENT_ID         VARCHAR(256)     NOT NULL,
    ROOT_CAUSE       VARCHAR(16777216),
    SEVERITY         VARCHAR(20),
    SUGGESTED_FIX    VARCHAR(16777216),
    FIX_SQL          VARCHAR(16777216),
    CONFIDENCE_SCORE FLOAT,
    RAW_RESPONSE     VARIANT,
    STATUS           VARCHAR(10)      NOT NULL DEFAULT 'PENDING',
    RETRY_COUNT      NUMBER(2,0)      NOT NULL DEFAULT 0,
    CREATED_AT       TIMESTAMP_LTZ    NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT       TIMESTAMP_LTZ    NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_ERROR_ANALYSIS PRIMARY KEY (EVENT_ID)
)
CLUSTER BY (CREATED_AT::DATE, STATUS)
DATA_RETENTION_TIME_IN_DAYS = 14
CHANGE_TRACKING = TRUE
COMMENT = 'Cortex AI analysis results for pipeline failure events';

CREATE OR REPLACE TABLE OPS_AI_MONITOR.AI_ENGINE.ALERT_LOG (
    EVENT_ID     VARCHAR(256)  NOT NULL,
    ALERT_FLAG   VARCHAR(10),
    ISSUE_TYPE   VARCHAR(100),
    ALERTED_AT   TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_ALERT_LOG PRIMARY KEY (EVENT_ID)
)
COMMENT = 'Tracks sent alerts to prevent duplicate notifications';

CREATE OR REPLACE TABLE OPS_AI_MONITOR.AI_ENGINE.AUTO_FIX_LOGS (
    EVENT_ID         VARCHAR(256)     NOT NULL,
    FIX_SQL          VARCHAR(16777216) NOT NULL,
    EXECUTION_STATUS VARCHAR(20)      NOT NULL,
    ERROR_MESSAGE    VARCHAR(16777216),
    EXECUTED_AT      TIMESTAMP_LTZ    NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_AUTO_FIX_LOGS PRIMARY KEY (EVENT_ID)
)
COMMENT = 'Tracks AI-suggested fixes that were auto-executed and their outcomes';

-- ============================================================================
-- SECTION 3: KNOWLEDGE BASE + CONFIG
-- ============================================================================

CREATE OR REPLACE TABLE OPS_AI_MONITOR.METADATA.ERROR_KB (
    PATTERN         VARCHAR(500)     NOT NULL,
    ROOT_CAUSE      VARCHAR(16777216) NOT NULL,
    RECOMMENDED_FIX VARCHAR(16777216) NOT NULL,
    FIX_SQL         VARCHAR(16777216),
    CONSTRAINT PK_ERROR_KB PRIMARY KEY (PATTERN)
)
COMMENT = 'Knowledge base of common error patterns for AI-enriched failure analysis';

INSERT INTO OPS_AI_MONITOR.METADATA.ERROR_KB
    (PATTERN, ROOT_CAUSE, RECOMMENDED_FIX, FIX_SQL)
VALUES
    ('does not exist',
     'Referenced object (table, view, schema, or database) is missing or has been dropped',
     'Verify the object name and schema path. Restore from Time Travel if recently dropped.',
     'UNDROP TABLE <database>.<schema>.<table>;'),

    ('object not found',
     'Object reference is invalid due to typo, wrong schema context, or the object was never created',
     'Check spelling, confirm the active database/schema context, or create the missing object.',
     'SHOW OBJECTS LIKE ''%<object_name>%'' IN DATABASE <database>;'),

    ('permission denied',
     'The executing role lacks the required privilege on the target object',
     'Grant the necessary privilege to the role, or switch to a role that already has access.',
     'GRANT SELECT ON TABLE <database>.<schema>.<table> TO ROLE <role>;'),

    ('insufficient privileges',
     'The executing role does not have USAGE on the database, schema, or warehouse, or lacks the required object-level privilege',
     'Grant USAGE on the container objects and the specific privilege on the target object.',
     'GRANT USAGE ON DATABASE <database> TO ROLE <role>; GRANT USAGE ON SCHEMA <database>.<schema> TO ROLE <role>;'),

    ('division by zero',
     'A numeric expression attempted to divide by zero at runtime',
     'Add a NULLIF or IFF guard around the divisor to prevent division by zero.',
     'SELECT numerator / NULLIF(denominator, 0) FROM <table>;'),

    ('warehouse is suspended',
     'The assigned warehouse is suspended and AUTO_RESUME is not enabled, or resume is in progress',
     'Resume the warehouse manually or enable AUTO_RESUME.',
     'ALTER WAREHOUSE <warehouse_name> RESUME; ALTER WAREHOUSE <warehouse_name> SET AUTO_RESUME = TRUE;'),

    ('stale',
     'Stream exceeded data retention period and can no longer track changes',
     'Recreate the stream to reset its offset. Increase DATA_RETENTION_TIME_IN_DAYS on source table.',
     'CREATE OR REPLACE STREAM <stream_name> ON TABLE <source_table>;'),

    ('change tracking',
     'Change tracking is not enabled or has expired for the source table used by a dynamic table or stream',
     'Enable change tracking on the source table.',
     'ALTER TABLE <table_name> SET CHANGE_TRACKING = TRUE;'),

    ('upstream',
     'A dynamic table refresh failed because an upstream dynamic table or source had errors',
     'Fix the upstream dynamic table first. Check the DAG in Snowsight under Transformation > Dynamic Tables.',
     'SELECT NAME, STATE, STATE_MESSAGE FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(ERROR_ONLY => TRUE));'),

    ('load failed',
     'Snowpipe or COPY INTO failed to load data from staged files due to format mismatch or corrupt data',
     'Check the file format, field delimiter, and encoding. Validate staged files before loading.',
     'SELECT * FROM TABLE(VALIDATE(<table>, JOB_ID => ''<job_id>''));'),

    ('file format',
     'The file format specified does not match the actual data layout in the staged file',
     'Verify the file format definition matches the source file structure (CSV, JSON, Parquet, etc.).',
     'DESC FILE FORMAT <file_format_name>;');

CREATE OR REPLACE TABLE OPS_AI_MONITOR.METADATA.ELT_WAREHOUSES (
    WAREHOUSE_NAME VARCHAR(256) NOT NULL,
    CONSTRAINT PK_ELT_WH PRIMARY KEY (WAREHOUSE_NAME)
)
COMMENT = 'Warehouses dedicated to ELT workloads for pipeline classification';

INSERT INTO OPS_AI_MONITOR.METADATA.ELT_WAREHOUSES (WAREHOUSE_NAME)
VALUES ('ETL_WH'), ('ELT_WH'), ('LOADING_WH'), ('TRANSFORM_WH'), ('DBT_WH');

-- ============================================================================
-- SECTION 4: VIEWS - DATA INGESTION
-- ============================================================================

CREATE OR REPLACE VIEW OPS_AI_MONITOR.EVENT_LOGS.V_UNIFIED_FAILURES
AS
SELECT
    QUERY_ID                                              AS EVENT_ID,
    'QUERY_REALTIME'                                      AS SOURCE_TYPE,
    ERROR_MESSAGE,
    QUERY_TEXT,
    USER_NAME,
    WAREHOUSE_NAME                                        AS WAREHOUSE,
    DATABASE_NAME                                         AS "DATABASE",
    SCHEMA_NAME                                           AS "SCHEMA",
    START_TIME
FROM TABLE(
    OPS_AI_MONITOR.INFORMATION_SCHEMA.QUERY_HISTORY(
        END_TIME_RANGE_START => DATEADD('MINUTES', -10, CURRENT_TIMESTAMP()),
        END_TIME_RANGE_END   => CURRENT_TIMESTAMP(),
        RESULT_LIMIT         => 10000
    )
)
WHERE EXECUTION_STATUS IN ('FAILED_WITH_ERROR', 'FAILED_WITH_INCIDENT')

UNION ALL

SELECT
    COALESCE(
        QUERY_ID,
        NAME || '_' || TO_VARCHAR(SCHEDULED_TIME, 'YYYYMMDDHH24MISS')
    )                                                     AS EVENT_ID,
    'TASK'                                                AS SOURCE_TYPE,
    ERROR_MESSAGE,
    QUERY_TEXT,
    NULL::VARCHAR                                         AS USER_NAME,
    NULL::VARCHAR                                         AS WAREHOUSE,
    DATABASE_NAME                                         AS "DATABASE",
    SCHEMA_NAME                                           AS "SCHEMA",
    COALESCE(QUERY_START_TIME, SCHEDULED_TIME)            AS START_TIME
FROM TABLE(
    SNOWFLAKE.INFORMATION_SCHEMA.TASK_HISTORY(
        SCHEDULED_TIME_RANGE_START => DATEADD('MINUTES', -10, CURRENT_TIMESTAMP()),
        SCHEDULED_TIME_RANGE_END   => CURRENT_TIMESTAMP(),
        RESULT_LIMIT               => 10000,
        ERROR_ONLY                 => TRUE
    )
)

UNION ALL

SELECT
    QUERY_ID                                              AS EVENT_ID,
    'QUERY_ACCOUNT_USAGE'                                 AS SOURCE_TYPE,
    ERROR_MESSAGE,
    QUERY_TEXT,
    USER_NAME,
    WAREHOUSE_NAME                                        AS WAREHOUSE,
    DATABASE_NAME                                         AS "DATABASE",
    SCHEMA_NAME                                           AS "SCHEMA",
    START_TIME
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE EXECUTION_STATUS IN ('FAIL', 'INCIDENT')
  AND START_TIME >= DATEADD('MINUTES', -10, CURRENT_TIMESTAMP())

UNION ALL

SELECT
    COALESCE(QUERY_ID, NAME || '_DT_' || TO_VARCHAR(DATA_TIMESTAMP, 'YYYYMMDDHH24MISS'))
                                                          AS EVENT_ID,
    'DYNAMIC_TABLE'                                       AS SOURCE_TYPE,
    STATE_MESSAGE                                         AS ERROR_MESSAGE,
    QUALIFIED_NAME                                        AS QUERY_TEXT,
    NULL::VARCHAR                                         AS USER_NAME,
    WAREHOUSE                                             AS WAREHOUSE,
    DATABASE_NAME                                         AS "DATABASE",
    SCHEMA_NAME                                           AS "SCHEMA",
    REFRESH_START_TIME                                    AS START_TIME
FROM TABLE(
    SNOWFLAKE.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
        ERROR_ONLY => TRUE
    )
)
WHERE REFRESH_START_TIME >= DATEADD('MINUTES', -10, CURRENT_TIMESTAMP())

UNION ALL

SELECT
    MD5(PIPE_NAME || FILE_NAME || TO_VARCHAR(LAST_LOAD_TIME))
                                                          AS EVENT_ID,
    'SNOWPIPE'                                            AS SOURCE_TYPE,
    FIRST_ERROR_MESSAGE                                   AS ERROR_MESSAGE,
    FILE_NAME                                             AS QUERY_TEXT,
    NULL::VARCHAR                                         AS USER_NAME,
    NULL::VARCHAR                                         AS WAREHOUSE,
    TABLE_CATALOG_NAME                                    AS "DATABASE",
    TABLE_SCHEMA_NAME                                     AS "SCHEMA",
    LAST_LOAD_TIME                                        AS START_TIME
FROM SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
WHERE STATUS IN ('Load failed', 'Partially loaded')
  AND LAST_LOAD_TIME >= DATEADD('HOURS', -2, CURRENT_TIMESTAMP())
  AND PIPE_NAME IS NOT NULL

UNION ALL

SELECT
    'STALE_STREAM_' || STREAM_NAME                        AS EVENT_ID,
    'STREAM_STALE'                                        AS SOURCE_TYPE,
    'Stream is stale: data retention period exceeded'     AS ERROR_MESSAGE,
    STREAM_NAME                                           AS QUERY_TEXT,
    NULL::VARCHAR                                         AS USER_NAME,
    NULL::VARCHAR                                         AS WAREHOUSE,
    DATABASE_NAME                                         AS "DATABASE",
    SCHEMA_NAME                                           AS "SCHEMA",
    DETECTED_AT                                           AS START_TIME
FROM OPS_AI_MONITOR.EVENT_LOGS.STALE_STREAMS
WHERE DETECTED_AT >= DATEADD('MINUTES', -10, CURRENT_TIMESTAMP())

UNION ALL

SELECT
    EVENT_ID,
    SOURCE_SYSTEM                                         AS SOURCE_TYPE,
    ERROR_MESSAGE,
    QUERY_TEXT,
    USER_NAME,
    WAREHOUSE_NAME                                        AS WAREHOUSE,
    DATABASE_NAME                                         AS "DATABASE",
    SCHEMA_NAME                                           AS "SCHEMA",
    START_TIME
FROM OPS_AI_MONITOR.EVENT_LOGS.CUSTOM_LOGS
WHERE STATUS = 'FAILED'
  AND CREATED_AT >= DATEADD('HOURS', -24, CURRENT_TIMESTAMP());

-- ============================================================================
-- SECTION 5: VIEWS - AI PROCESSING
-- ============================================================================

CREATE OR REPLACE VIEW OPS_AI_MONITOR.AI_ENGINE.V_AI_QUEUE
AS
SELECT
    FE.EVENT_ID,
    FE.ERROR_MESSAGE,
    FE.QUERY_TEXT,
    FE.START_TIME
FROM OPS_AI_MONITOR.EVENT_LOGS.FAILURE_EVENTS FE
LEFT JOIN OPS_AI_MONITOR.AI_ENGINE.ERROR_ANALYSIS EA
    ON FE.EVENT_ID = EA.EVENT_ID
WHERE EA.EVENT_ID IS NULL
   OR (EA.STATUS = 'FAILED' AND EA.RETRY_COUNT < 3)
ORDER BY FE.START_TIME DESC
LIMIT 20;

CREATE OR REPLACE VIEW OPS_AI_MONITOR.AI_ENGINE.V_FAILURE_INSIGHTS
AS
SELECT
    FE.EVENT_ID,
    FE.ERROR_MESSAGE,
    FE.QUERY_TEXT,
    FE.START_TIME,
    EA.ROOT_CAUSE,
    EA.SEVERITY,
    EA.SUGGESTED_FIX,
    EA.FIX_SQL,
    EA.CONFIDENCE_SCORE,
    COALESCE(EA.STATUS, 'PENDING') AS STATUS
FROM OPS_AI_MONITOR.EVENT_LOGS.FAILURE_EVENTS FE
LEFT JOIN OPS_AI_MONITOR.AI_ENGINE.ERROR_ANALYSIS EA
    ON FE.EVENT_ID = EA.EVENT_ID
ORDER BY FE.START_TIME DESC;

-- ============================================================================
-- SECTION 6: VIEWS - CLASSIFICATION & ENRICHMENT
-- ============================================================================

CREATE OR REPLACE VIEW OPS_AI_MONITOR.AI_ENGINE.V_FAILURE_INSIGHTS_ENRICHED
AS
SELECT
    FE.EVENT_ID,
    FE.SOURCE_TYPE,
    FE.ERROR_MESSAGE,
    FE.QUERY_TEXT,
    FE.USER_NAME,
    FE.WAREHOUSE_NAME,
    FE.DATABASE_NAME,
    FE.SCHEMA_NAME,
    FE.START_TIME,

    CASE
        WHEN FE.SOURCE_TYPE = 'FIVETRAN'                                         THEN 'FIVETRAN'
        WHEN FE.SOURCE_TYPE = 'DBT'                                              THEN 'DBT'
        WHEN FE.SOURCE_TYPE = 'CUSTOM'                                           THEN 'CUSTOM_ETL'
        WHEN FE.SOURCE_TYPE = 'DYNAMIC_TABLE'                                    THEN 'DYNAMIC_TABLE'
        WHEN FE.SOURCE_TYPE = 'SNOWPIPE'                                         THEN 'SNOWPIPE'
        WHEN FE.SOURCE_TYPE = 'STREAM_STALE'                                     THEN 'STREAM'
        WHEN FE.SOURCE_TYPE = 'TASK'                                             THEN 'TASK'
        WHEN UPPER(FE.QUERY_TEXT) LIKE '%CALL %'
          OR UPPER(FE.QUERY_TEXT) LIKE '%CREATE%PROCEDURE%'                      THEN 'STORED_PROC'
        WHEN UPPER(FE.QUERY_TEXT) LIKE '%CREATE%FUNCTION%'
          OR UPPER(FE.QUERY_TEXT) LIKE '%CREATE%EXTERNAL FUNCTION%'              THEN 'FUNCTION'
        WHEN UPPER(FE.QUERY_TEXT) LIKE '%CREATE%STREAM%'
          OR UPPER(FE.QUERY_TEXT) LIKE '%INSERT%STREAM%'                         THEN 'STREAM'
        WHEN UPPER(FE.QUERY_TEXT) LIKE '%CREATE%DYNAMIC TABLE%'
          OR UPPER(FE.QUERY_TEXT) LIKE '%ALTER%DYNAMIC TABLE%'                   THEN 'DYNAMIC_TABLE'
        WHEN UPPER(FE.QUERY_TEXT) LIKE '%COPY INTO%'                             THEN 'ELT'
        WHEN EW.WAREHOUSE_NAME IS NOT NULL                                       THEN 'ELT'
        ELSE 'SQL'
    END AS PIPELINE_TYPE,

    CASE
        WHEN FE.ERROR_MESSAGE ILIKE '%does not exist%'
          OR FE.ERROR_MESSAGE ILIKE '%object%not found%'
          OR FE.ERROR_MESSAGE ILIKE '%unknown%table%'
          OR FE.ERROR_MESSAGE ILIKE '%unknown%column%'
          OR FE.ERROR_MESSAGE ILIKE '%invalid identifier%'                       THEN 'MISSING_OBJECT'
        WHEN FE.ERROR_MESSAGE ILIKE '%insufficient privileges%'
          OR FE.ERROR_MESSAGE ILIKE '%access denied%'
          OR FE.ERROR_MESSAGE ILIKE '%not authorized%'
          OR FE.ERROR_MESSAGE ILIKE '%permission%denied%'                        THEN 'PERMISSION'
        WHEN FE.ERROR_MESSAGE ILIKE '%SQL compilation error%'
          OR FE.ERROR_MESSAGE ILIKE '%syntax error%'
          OR FE.ERROR_MESSAGE ILIKE '%unexpected%'
          OR FE.ERROR_MESSAGE ILIKE '%invalid%expression%'
          OR FE.ERROR_MESSAGE ILIKE '%parse error%'
          OR FE.ERROR_MESSAGE ILIKE '%compilation error%'                        THEN 'SYNTAX'
        WHEN FE.ERROR_MESSAGE ILIKE '%division by zero%'
          OR FE.ERROR_MESSAGE ILIKE '%numeric value%'
          OR FE.ERROR_MESSAGE ILIKE '%out of range%'
          OR FE.ERROR_MESSAGE ILIKE '%timeout%'
          OR FE.ERROR_MESSAGE ILIKE '%resource%'
          OR FE.ERROR_MESSAGE ILIKE '%execution error%'
          OR FE.ERROR_MESSAGE ILIKE '%warehouse%unavailable%'
          OR FE.ERROR_MESSAGE ILIKE '%heap space%'
          OR FE.ERROR_MESSAGE ILIKE '%OutOfMemory%'                              THEN 'RUNTIME'
        WHEN FE.ERROR_MESSAGE ILIKE '%stale%'
          OR FE.ERROR_MESSAGE ILIKE '%retention%'
          OR FE.SOURCE_TYPE = 'STREAM_STALE'                                     THEN 'STALENESS'
        WHEN FE.ERROR_MESSAGE ILIKE '%load failed%'
          OR FE.ERROR_MESSAGE ILIKE '%file format%'
          OR FE.ERROR_MESSAGE ILIKE '%field delimiter%'
          OR FE.SOURCE_TYPE = 'SNOWPIPE'                                         THEN 'DATA_LOAD'
        WHEN FE.ERROR_MESSAGE ILIKE '%upstream%fail%'
          OR FE.ERROR_MESSAGE ILIKE '%change tracking%'
          OR FE.ERROR_MESSAGE ILIKE '%depends on%'
          OR FE.ERROR_MESSAGE ILIKE '%was not found%'                            THEN 'DEPENDENCY'
        WHEN FE.ERROR_MESSAGE ILIKE '%connection%'
          OR FE.ERROR_MESSAGE ILIKE '%SSL%'
          OR FE.ERROR_MESSAGE ILIKE '%rate limit%'
          OR FE.ERROR_MESSAGE ILIKE '%HTTP 429%'
          OR FE.ERROR_MESSAGE ILIKE '%API%'                                      THEN 'CONNECTIVITY'
        WHEN FE.ERROR_MESSAGE ILIKE '%schema drift%'
          OR FE.ERROR_MESSAGE ILIKE '%column%removed%'
          OR FE.ERROR_MESSAGE ILIKE '%schema%change%'                            THEN 'SCHEMA_DRIFT'
        ELSE 'OTHER'
    END AS ERROR_CATEGORY,

    EA.ROOT_CAUSE,
    EA.SEVERITY,
    EA.SUGGESTED_FIX,
    EA.FIX_SQL,
    EA.CONFIDENCE_SCORE,
    COALESCE(EA.STATUS, 'PENDING') AS STATUS

FROM OPS_AI_MONITOR.EVENT_LOGS.FAILURE_EVENTS FE
LEFT JOIN OPS_AI_MONITOR.AI_ENGINE.ERROR_ANALYSIS EA
    ON FE.EVENT_ID = EA.EVENT_ID
LEFT JOIN OPS_AI_MONITOR.METADATA.ELT_WAREHOUSES EW
    ON FE.WAREHOUSE_NAME = EW.WAREHOUSE_NAME
ORDER BY FE.START_TIME DESC;

-- ============================================================================
-- SECTION 7: VIEWS - OBSERVABILITY & ALERTING
-- ============================================================================

CREATE OR REPLACE VIEW OPS_AI_MONITOR.AI_ENGINE.V_FAILURE_METRICS
AS
SELECT
    COUNT(*)                                                              AS TOTAL_FAILURES,
    COUNT_IF(FE.SOURCE_TYPE IN ('QUERY_REALTIME', 'QUERY_ACCOUNT_USAGE')) AS QUERY_FAILURES,
    COUNT_IF(FE.SOURCE_TYPE = 'TASK')                                     AS TASK_FAILURES,
    COUNT_IF(FE.SOURCE_TYPE = 'DYNAMIC_TABLE')                            AS DYNAMIC_TABLE_FAILURES,
    COUNT_IF(FE.SOURCE_TYPE = 'SNOWPIPE')                                 AS SNOWPIPE_FAILURES,
    COUNT_IF(FE.SOURCE_TYPE = 'STREAM_STALE')                             AS STREAM_FAILURES,
    COUNT_IF(FE.SOURCE_TYPE IN ('FIVETRAN', 'DBT', 'CUSTOM'))            AS EXTERNAL_FAILURES,
    COUNT_IF(FE.ERROR_MESSAGE ILIKE '%does not exist%'
          OR FE.ERROR_MESSAGE ILIKE '%not authorized%')                   AS MISSING_OBJECT_COUNT,
    COUNT_IF(EA.SEVERITY = 'HIGH')                                        AS HIGH_SEVERITY_COUNT,
    COUNT_IF(EA.SEVERITY = 'MEDIUM')                                      AS MEDIUM_SEVERITY_COUNT,
    COUNT_IF(EA.SEVERITY = 'LOW')                                         AS LOW_SEVERITY_COUNT,
    COUNT_IF(EA.STATUS = 'SUCCESS')                                       AS AI_SUCCESS_COUNT,
    COUNT_IF(EA.STATUS = 'FAILED')                                        AS AI_FAILED_COUNT,
    COUNT_IF(EA.EVENT_ID IS NULL)                                         AS AI_PENDING_COUNT,
    ROUND(COUNT_IF(EA.STATUS = 'SUCCESS') * 100.0 / NULLIF(COUNT(*), 0), 1) AS AI_SUCCESS_RATE_PCT,
    MIN(FE.START_TIME)                                                    AS EARLIEST_FAILURE,
    MAX(FE.START_TIME)                                                    AS LATEST_FAILURE
FROM OPS_AI_MONITOR.EVENT_LOGS.FAILURE_EVENTS FE
LEFT JOIN OPS_AI_MONITOR.AI_ENGINE.ERROR_ANALYSIS EA
    ON FE.EVENT_ID = EA.EVENT_ID
WHERE FE.START_TIME >= DATEADD('DAY', -1, CURRENT_TIMESTAMP());

CREATE OR REPLACE VIEW OPS_AI_MONITOR.AI_ENGINE.V_SLA_BREACH
AS
SELECT
    FE.EVENT_ID,
    VE.PIPELINE_TYPE,
    FE.SOURCE_TYPE,
    ROUND(QH.TOTAL_ELAPSED_TIME / 1000, 1)               AS EXECUTION_TIME_SECONDS,
    CASE
        WHEN QH.TOTAL_ELAPSED_TIME / 1000 > 300 THEN 'BREACHED'
        ELSE 'OK'
    END                                                    AS SLA_STATUS,
    CASE
        WHEN QH.TOTAL_ELAPSED_TIME / 1000 > 600 THEN 'CRITICAL: exceeded 2x SLA (>10 min)'
        WHEN QH.TOTAL_ELAPSED_TIME / 1000 > 300 THEN 'WARNING: exceeded SLA threshold (>5 min)'
        ELSE 'Within SLA'
    END                                                    AS BREACH_REASON,
    VE.ERROR_CATEGORY,
    VE.SEVERITY,
    FE.START_TIME
FROM OPS_AI_MONITOR.EVENT_LOGS.FAILURE_EVENTS FE
INNER JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY QH
    ON FE.EVENT_ID = QH.QUERY_ID
LEFT JOIN OPS_AI_MONITOR.AI_ENGINE.V_FAILURE_INSIGHTS_ENRICHED VE
    ON FE.EVENT_ID = VE.EVENT_ID
WHERE FE.START_TIME >= DATEADD('DAY', -1, CURRENT_TIMESTAMP())
ORDER BY EXECUTION_TIME_SECONDS DESC;

CREATE OR REPLACE VIEW OPS_AI_MONITOR.AI_ENGINE.V_SLA_SUMMARY
AS
SELECT
    PIPELINE_TYPE,
    COUNT(*)                                                             AS TOTAL_RUNS,
    COUNT_IF(SLA_STATUS = 'BREACHED')                                    AS BREACHED_RUNS,
    ROUND((COUNT(*) - COUNT_IF(SLA_STATUS = 'BREACHED')) * 100.0
          / NULLIF(COUNT(*), 0), 1)                                      AS SUCCESS_RATE_PCT,
    ROUND(AVG(EXECUTION_TIME_SECONDS), 2)                                AS AVG_EXECUTION_TIME_SEC,
    ROUND(MAX(EXECUTION_TIME_SECONDS), 2)                                AS MAX_EXECUTION_TIME_SEC,
    ROUND(MEDIAN(EXECUTION_TIME_SECONDS), 2)                             AS P50_EXECUTION_TIME_SEC
FROM OPS_AI_MONITOR.AI_ENGINE.V_SLA_BREACH
GROUP BY PIPELINE_TYPE
ORDER BY BREACHED_RUNS DESC, TOTAL_RUNS DESC;

CREATE OR REPLACE VIEW OPS_AI_MONITOR.AI_ENGINE.V_CRITICAL_ALERTS
AS
WITH REPEAT_OFFENDERS AS (
    SELECT
        EVENT_ID,
        ERROR_MESSAGE,
        COUNT(*) OVER (
            PARTITION BY ERROR_MESSAGE
            ORDER BY START_TIME
            RANGE BETWEEN INTERVAL '10 MINUTES' PRECEDING AND CURRENT ROW
        ) AS FAILURES_IN_WINDOW
    FROM OPS_AI_MONITOR.EVENT_LOGS.FAILURE_EVENTS
    WHERE START_TIME >= DATEADD('DAY', -1, CURRENT_TIMESTAMP())
),
SLA AS (
    SELECT EVENT_ID, SLA_STATUS
    FROM OPS_AI_MONITOR.AI_ENGINE.V_SLA_BREACH
    WHERE SLA_STATUS = 'BREACHED'
)
SELECT
    FE.EVENT_ID,
    VE.PIPELINE_TYPE,
    VE.ERROR_CATEGORY,
    VE.SEVERITY,
    CASE
        WHEN VE.SEVERITY = 'HIGH' AND SLA.EVENT_ID IS NOT NULL AND RO.FAILURES_IN_WINDOW > 3
            THEN 'HIGH_SEV + SLA_BREACH + REPEATED'
        WHEN VE.SEVERITY = 'HIGH' AND SLA.EVENT_ID IS NOT NULL
            THEN 'HIGH_SEV + SLA_BREACH'
        WHEN VE.SEVERITY = 'HIGH' AND RO.FAILURES_IN_WINDOW > 3
            THEN 'HIGH_SEV + REPEATED'
        WHEN SLA.EVENT_ID IS NOT NULL AND RO.FAILURES_IN_WINDOW > 3
            THEN 'SLA_BREACH + REPEATED'
        WHEN VE.SEVERITY = 'HIGH'
            THEN 'HIGH_SEVERITY'
        WHEN SLA.EVENT_ID IS NOT NULL
            THEN 'SLA_BREACH'
        WHEN RO.FAILURES_IN_WINDOW > 3
            THEN 'REPEATED_FAILURE'
    END AS ISSUE_TYPE,
    CASE
        WHEN VE.SEVERITY = 'HIGH' AND SLA.EVENT_ID IS NOT NULL  THEN 'P1'
        WHEN VE.SEVERITY = 'HIGH' OR SLA.EVENT_ID IS NOT NULL   THEN 'P2'
        WHEN RO.FAILURES_IN_WINDOW > 3                          THEN 'P3'
    END AS ALERT_FLAG,
    RO.FAILURES_IN_WINDOW,
    FE.ERROR_MESSAGE,
    FE.START_TIME
FROM OPS_AI_MONITOR.EVENT_LOGS.FAILURE_EVENTS FE
JOIN OPS_AI_MONITOR.AI_ENGINE.V_FAILURE_INSIGHTS_ENRICHED VE
    ON FE.EVENT_ID = VE.EVENT_ID
LEFT JOIN SLA
    ON FE.EVENT_ID = SLA.EVENT_ID
LEFT JOIN REPEAT_OFFENDERS RO
    ON FE.EVENT_ID = RO.EVENT_ID
WHERE FE.START_TIME >= DATEADD('DAY', -1, CURRENT_TIMESTAMP())
  AND (VE.SEVERITY = 'HIGH'
       OR SLA.EVENT_ID IS NOT NULL
       OR RO.FAILURES_IN_WINDOW > 3)
ORDER BY
    CASE ALERT_FLAG WHEN 'P1' THEN 1 WHEN 'P2' THEN 2 WHEN 'P3' THEN 3 END,
    FE.START_TIME DESC;

-- ============================================================================
-- SECTION 8: TASKS (DAG)
-- ============================================================================

CREATE OR REPLACE TASK OPS_AI_MONITOR.EVENT_LOGS.TSK_INGEST_FAILURES
    WAREHOUSE = OPS_MONITOR_WH
    SCHEDULE  = '1 MINUTE'
    SUSPEND_TASK_AFTER_NUM_FAILURES = 5
    TASK_AUTO_RETRY_ATTEMPTS = 1
    COMMENT   = 'Merges new failure events from unified view into persisted table every 1 minute'
AS
    MERGE INTO OPS_AI_MONITOR.EVENT_LOGS.FAILURE_EVENTS AS TGT
    USING (
        SELECT
            EVENT_ID,
            SOURCE_TYPE,
            ERROR_MESSAGE,
            QUERY_TEXT,
            USER_NAME,
            WAREHOUSE        AS WAREHOUSE_NAME,
            "DATABASE"       AS DATABASE_NAME,
            "SCHEMA"         AS SCHEMA_NAME,
            START_TIME
        FROM OPS_AI_MONITOR.EVENT_LOGS.V_UNIFIED_FAILURES
    ) AS SRC
        ON  TGT.EVENT_ID    = SRC.EVENT_ID
        AND TGT.SOURCE_TYPE = SRC.SOURCE_TYPE
    WHEN NOT MATCHED THEN INSERT (
        EVENT_ID, SOURCE_TYPE, ERROR_MESSAGE, QUERY_TEXT,
        USER_NAME, WAREHOUSE_NAME, DATABASE_NAME, SCHEMA_NAME,
        START_TIME
    )
    VALUES (
        SRC.EVENT_ID, SRC.SOURCE_TYPE, SRC.ERROR_MESSAGE, SRC.QUERY_TEXT,
        SRC.USER_NAME, SRC.WAREHOUSE_NAME, SRC.DATABASE_NAME, SRC.SCHEMA_NAME,
        SRC.START_TIME
    );

CREATE OR REPLACE TASK OPS_AI_MONITOR.EVENT_LOGS.TSK_AI_ANALYZE
    WAREHOUSE = OPS_MONITOR_WH
    COMMENT = 'Runs KB-enriched Cortex COMPLETE on queued failures via V_AI_QUEUE, 10 per run'
    AFTER OPS_AI_MONITOR.EVENT_LOGS.TSK_INGEST_FAILURES
AS
    MERGE INTO OPS_AI_MONITOR.AI_ENGINE.ERROR_ANALYSIS AS TGT
    USING (
        WITH QUEUED AS (
            SELECT EVENT_ID, ERROR_MESSAGE, QUERY_TEXT
            FROM OPS_AI_MONITOR.AI_ENGINE.V_AI_QUEUE
            LIMIT 10
        ),
        KB_ENRICHED AS (
            SELECT
                Q.EVENT_ID,
                Q.ERROR_MESSAGE,
                Q.QUERY_TEXT,
                KB.RECOMMENDED_FIX AS KB_HINT,
                KB.FIX_SQL         AS KB_FIX_SQL
            FROM QUEUED Q
            LEFT JOIN OPS_AI_MONITOR.METADATA.ERROR_KB KB
                ON Q.ERROR_MESSAGE ILIKE '%' || KB.PATTERN || '%'
            QUALIFY ROW_NUMBER() OVER (
                PARTITION BY Q.EVENT_ID
                ORDER BY LENGTH(KB.PATTERN) DESC NULLS LAST
            ) = 1
        ),
        AI_RAW AS (
            SELECT
                EVENT_ID,
                SNOWFLAKE.CORTEX.COMPLETE(
                    'mistral-large2',
                    CONCAT(
                        'You are a Snowflake SQL expert analyzing pipeline failures. ',
                        'Determine root cause and provide an actionable fix.\n\n',
                        'Common failure categories: missing object, insufficient privileges, ',
                        'SQL syntax error, division by zero, data type mismatch, resource contention.\n\n',
                        'ERROR: ', COALESCE(LEFT(ERROR_MESSAGE, 1000), 'N/A'), '\n\n',
                        'QUERY: ', COALESCE(LEFT(QUERY_TEXT, 2000), 'N/A'), '\n\n',
                        IFF(KB_HINT IS NOT NULL,
                            CONCAT('Hint from knowledge base: ', KB_HINT, '\n',
                                   'Reference fix: ', COALESCE(KB_FIX_SQL, 'N/A'), '\n\n'),
                            ''),
                        'Return ONLY a valid JSON object with these exact keys:\n',
                        '{"root_cause":"...","severity":"LOW|MEDIUM|HIGH",',
                        '"suggested_fix":"...","fix_sql":"...","confidence_score":0.0}\n\n',
                        'Rules:\n',
                        '- fix_sql must be executable Snowflake SQL, or empty string if not applicable\n',
                        '- confidence_score between 0.0 and 1.0\n',
                        '- No markdown. No explanation. JSON only.'
                    )
                ) AS RAW_RESPONSE
            FROM KB_ENRICHED
        ),
        AI_PARSED AS (
            SELECT
                EVENT_ID,
                RAW_RESPONSE,
                TRY_PARSE_JSON(
                    TRIM(REGEXP_REPLACE(RAW_RESPONSE, '```[a-zA-Z]*|```', ''))
                ) AS PARSED
            FROM AI_RAW
        )
        SELECT
            EVENT_ID,
            PARSED:root_cause::VARCHAR                AS ROOT_CAUSE,
            PARSED:severity::VARCHAR                  AS SEVERITY,
            PARSED:suggested_fix::VARCHAR             AS SUGGESTED_FIX,
            PARSED:fix_sql::VARCHAR                   AS FIX_SQL,
            PARSED:confidence_score::FLOAT            AS CONFIDENCE_SCORE,
            COALESCE(PARSED, OBJECT_CONSTRUCT(
                'error', 'PARSE_FAILED',
                'raw', RAW_RESPONSE
            ))                                        AS RESPONSE_VARIANT,
            IFF(PARSED IS NOT NULL, 'SUCCESS', 'FAILED') AS STATUS
        FROM AI_PARSED
    ) AS SRC
    ON TGT.EVENT_ID = SRC.EVENT_ID
    WHEN MATCHED THEN UPDATE SET
        TGT.ROOT_CAUSE       = SRC.ROOT_CAUSE,
        TGT.SEVERITY         = SRC.SEVERITY,
        TGT.SUGGESTED_FIX    = SRC.SUGGESTED_FIX,
        TGT.FIX_SQL          = SRC.FIX_SQL,
        TGT.CONFIDENCE_SCORE = SRC.CONFIDENCE_SCORE,
        TGT.RAW_RESPONSE     = SRC.RESPONSE_VARIANT,
        TGT.STATUS           = SRC.STATUS,
        TGT.RETRY_COUNT      = TGT.RETRY_COUNT + 1,
        TGT.UPDATED_AT       = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (
        EVENT_ID, ROOT_CAUSE, SEVERITY, SUGGESTED_FIX, FIX_SQL,
        CONFIDENCE_SCORE, RAW_RESPONSE, STATUS
    )
    VALUES (
        SRC.EVENT_ID, SRC.ROOT_CAUSE, SRC.SEVERITY, SRC.SUGGESTED_FIX, SRC.FIX_SQL,
        SRC.CONFIDENCE_SCORE, SRC.RESPONSE_VARIANT, SRC.STATUS
    );

CREATE OR REPLACE TASK OPS_AI_MONITOR.EVENT_LOGS.TSK_SEND_ALERTS
    WAREHOUSE = OPS_MONITOR_WH
    COMMENT = 'Sends email alerts for HIGH severity and SLA breaches, skips already-alerted events'
    AFTER OPS_AI_MONITOR.EVENT_LOGS.TSK_AI_ANALYZE
AS
DECLARE
    ALERT_COUNT INT;
    ALERT_BODY  VARCHAR;
BEGIN
    CREATE OR REPLACE TEMPORARY TABLE OPS_AI_MONITOR.EVENT_LOGS.TMP_NEW_ALERTS AS
    SELECT
        CA.EVENT_ID,
        CA.ALERT_FLAG,
        CA.ISSUE_TYPE,
        CA.PIPELINE_TYPE,
        CA.SEVERITY,
        LEFT(CA.ERROR_MESSAGE, 200) AS ERROR_SNIPPET,
        CA.START_TIME
    FROM OPS_AI_MONITOR.AI_ENGINE.V_CRITICAL_ALERTS CA
    LEFT JOIN OPS_AI_MONITOR.AI_ENGINE.ALERT_LOG AL
        ON CA.EVENT_ID = AL.EVENT_ID
    WHERE AL.EVENT_ID IS NULL
    ORDER BY CA.ALERT_FLAG, CA.START_TIME DESC
    LIMIT 20;

    SELECT COUNT(*) INTO :ALERT_COUNT FROM OPS_AI_MONITOR.EVENT_LOGS.TMP_NEW_ALERTS;

    IF (:ALERT_COUNT > 0) THEN
        SELECT CONCAT(
            'Pipeline Failure Alerts: ', :ALERT_COUNT, ' new critical event(s)\n',
            '─────────────────────────────────────────\n\n',
            LISTAGG(
                CONCAT(
                    '[', ALERT_FLAG, '] ', ISSUE_TYPE, '\n',
                    'Pipeline: ', PIPELINE_TYPE, ' | Severity: ', SEVERITY, '\n',
                    'Error: ', ERROR_SNIPPET, '\n',
                    'Time: ', TO_VARCHAR(START_TIME, 'YYYY-MM-DD HH24:MI:SS'), '\n',
                    'Event: ', EVENT_ID, '\n'
                ),
                '\n─────────────────────────────────────────\n'
            ) WITHIN GROUP (ORDER BY ALERT_FLAG, START_TIME DESC),
            '\n─────────────────────────────────────────\n',
            'Dashboard: OPS_AI_MONITOR.AI_ENGINE.FAILURE_DASHBOARD'
        ) INTO :ALERT_BODY
        FROM OPS_AI_MONITOR.EVENT_LOGS.TMP_NEW_ALERTS;

        CALL SYSTEM$SEND_EMAIL(
            'OPS_ALERT_EMAIL',
            'riteshmeshram0503@gmail.com',
            CONCAT('ALERT: ', :ALERT_COUNT, ' Pipeline Failure(s) Detected'),
            :ALERT_BODY
        );

        INSERT INTO OPS_AI_MONITOR.AI_ENGINE.ALERT_LOG (EVENT_ID, ALERT_FLAG, ISSUE_TYPE)
        SELECT EVENT_ID, ALERT_FLAG, ISSUE_TYPE
        FROM OPS_AI_MONITOR.EVENT_LOGS.TMP_NEW_ALERTS;
    END IF;

    DROP TABLE IF EXISTS OPS_AI_MONITOR.EVENT_LOGS.TMP_NEW_ALERTS;

    RETURN CONCAT(:ALERT_COUNT, ' alerts sent');
END;

CREATE OR REPLACE TASK OPS_AI_MONITOR.EVENT_LOGS.TSK_AUTO_FIX
    WAREHOUSE = OPS_MONITOR_WH
    COMMENT = 'Auto-executes safe AI-suggested fixes for LOW/MEDIUM severity failures'
    AFTER OPS_AI_MONITOR.EVENT_LOGS.TSK_AI_ANALYZE
AS
DECLARE
    C1 CURSOR FOR
        SELECT EA.EVENT_ID, EA.FIX_SQL
        FROM OPS_AI_MONITOR.AI_ENGINE.ERROR_ANALYSIS EA
        LEFT JOIN OPS_AI_MONITOR.AI_ENGINE.AUTO_FIX_LOGS AFL
            ON EA.EVENT_ID = AFL.EVENT_ID
        WHERE EA.STATUS = 'SUCCESS'
          AND EA.SEVERITY IN ('LOW', 'MEDIUM')
          AND EA.FIX_SQL IS NOT NULL
          AND TRIM(EA.FIX_SQL) != ''
          AND EA.CONFIDENCE_SCORE >= 0.8
          AND AFL.EVENT_ID IS NULL
          AND UPPER(EA.FIX_SQL) NOT LIKE '%DROP %'
          AND UPPER(EA.FIX_SQL) NOT LIKE '%DELETE %'
          AND UPPER(EA.FIX_SQL) NOT LIKE '%TRUNCATE %'
          AND UPPER(EA.FIX_SQL) NOT LIKE '%INSERT %'
          AND UPPER(EA.FIX_SQL) NOT LIKE '%UPDATE %'
          AND UPPER(EA.FIX_SQL) NOT LIKE '%MERGE %'
          AND UPPER(EA.FIX_SQL) NOT LIKE '%CREATE OR REPLACE %'
          AND UPPER(EA.FIX_SQL) NOT LIKE '%REVOKE %'
          AND EA.CREATED_AT >= DATEADD('HOUR', -1, CURRENT_TIMESTAMP())
        ORDER BY EA.CREATED_AT DESC
        LIMIT 5;
    V_EVENT_ID VARCHAR;
    V_FIX_SQL  VARCHAR;
BEGIN
    OPEN C1;
    FOR REC IN C1 DO
        V_EVENT_ID := REC.EVENT_ID;
        V_FIX_SQL  := REC.FIX_SQL;
        BEGIN
            EXECUTE IMMEDIATE :V_FIX_SQL;
            INSERT INTO OPS_AI_MONITOR.AI_ENGINE.AUTO_FIX_LOGS
                (EVENT_ID, FIX_SQL, EXECUTION_STATUS)
            VALUES (:V_EVENT_ID, :V_FIX_SQL, 'SUCCESS');
        EXCEPTION
            WHEN OTHER THEN
                INSERT INTO OPS_AI_MONITOR.AI_ENGINE.AUTO_FIX_LOGS
                    (EVENT_ID, FIX_SQL, EXECUTION_STATUS, ERROR_MESSAGE)
                VALUES (:V_EVENT_ID, :V_FIX_SQL, 'FAILED', SQLERRM);
        END;
    END FOR;
    CLOSE C1;
    RETURN 'Auto-fix cycle complete';
END;

ALTER TASK OPS_AI_MONITOR.EVENT_LOGS.TSK_AUTO_FIX RESUME;
ALTER TASK OPS_AI_MONITOR.EVENT_LOGS.TSK_SEND_ALERTS RESUME;
ALTER TASK OPS_AI_MONITOR.EVENT_LOGS.TSK_AI_ANALYZE RESUME;
ALTER TASK OPS_AI_MONITOR.EVENT_LOGS.TSK_INGEST_FAILURES RESUME;

-- ============================================================================
-- SECTION 9: STREAMLIT DASHBOARD
-- ============================================================================

CREATE STAGE IF NOT EXISTS OPS_AI_MONITOR.AI_ENGINE.STREAMLIT_STAGE;

CREATE OR REPLACE STREAMLIT OPS_AI_MONITOR.AI_ENGINE.FAILURE_DASHBOARD
    FROM '@OPS_AI_MONITOR.AI_ENGINE.STREAMLIT_STAGE'
    MAIN_FILE = 'streamlit_app.py'
    COMMENT = 'AI Pipeline Failure Investigator dashboard with CoCo AI assistant';

ALTER STREAMLIT OPS_AI_MONITOR.AI_ENGINE.FAILURE_DASHBOARD
    SET QUERY_WAREHOUSE = OPS_MONITOR_WH;

-- ============================================================================
-- SECTION 10: CUSTOM LOGS SAMPLE DATA (Fivetran / dbt / custom ETL)
-- ============================================================================

INSERT INTO OPS_AI_MONITOR.EVENT_LOGS.CUSTOM_LOGS
    (PIPELINE_NAME, SOURCE_SYSTEM, ERROR_MESSAGE, QUERY_TEXT, STATUS, DATABASE_NAME, SCHEMA_NAME, START_TIME)
VALUES
    ('fivetran_salesforce_sync', 'FIVETRAN',
     'Connection timeout: Salesforce API did not respond within 120 seconds',
     'SYNC salesforce.accounts -> RAW.SALESFORCE_ACCOUNTS', 'FAILED',
     'RAW', 'SALESFORCE', DATEADD('MINUTES', -45, CURRENT_TIMESTAMP())),

    ('fivetran_stripe_sync', 'FIVETRAN',
     'Schema drift detected: column payment_method_id removed from source',
     'SYNC stripe.payments -> RAW.STRIPE_PAYMENTS', 'FAILED',
     'RAW', 'STRIPE', DATEADD('MINUTES', -30, CURRENT_TIMESTAMP())),

    ('fivetran_hubspot_sync', 'FIVETRAN',
     'Rate limit exceeded: HubSpot API returned HTTP 429',
     'SYNC hubspot.contacts -> RAW.HUBSPOT_CONTACTS', 'FAILED',
     'RAW', 'HUBSPOT', DATEADD('MINUTES', -15, CURRENT_TIMESTAMP())),

    ('dbt_stg_orders', 'DBT',
     'Compilation Error: Model stg_orders depends on source raw.orders which was not found',
     'dbt run --select stg_orders', 'FAILED',
     'ANALYTICS', 'STAGING', DATEADD('HOURS', -2, CURRENT_TIMESTAMP())),

    ('dbt_fct_revenue', 'DBT',
     'Database Error: Division by zero in model fct_revenue at line 42',
     'SELECT order_total / NULLIF(order_count, 0) FROM analytics.staging.stg_orders', 'FAILED',
     'ANALYTICS', 'MARTS', DATEADD('HOURS', -1, CURRENT_TIMESTAMP())),

    ('dbt_test_unique_order_id', 'DBT',
     'Failure in test unique_order_id: Got 23 results, configured to fail if != 0',
     'dbt test --select unique_order_id', 'FAILED',
     'ANALYTICS', 'TESTS', DATEADD('MINUTES', -50, CURRENT_TIMESTAMP())),

    ('custom_etl_inventory_load', 'CUSTOM',
     'COPY INTO failed: field delimiter mismatch in file inventory_20260320.csv',
     'COPY INTO WAREHOUSE_DB.PUBLIC.INVENTORY FROM @S3_STAGE/inventory_20260320.csv', 'FAILED',
     'WAREHOUSE_DB', 'PUBLIC', DATEADD('HOURS', -3, CURRENT_TIMESTAMP())),

    ('custom_etl_user_merge', 'CUSTOM',
     'Insufficient privileges to insert into PROD.CORE.DIM_USERS',
     'MERGE INTO PROD.CORE.DIM_USERS USING RAW.CRM.USERS ON user_id = user_id', 'FAILED',
     'PROD', 'CORE', DATEADD('MINUTES', -90, CURRENT_TIMESTAMP())),

    ('custom_spark_ingest', 'CUSTOM',
     'Java heap space: OutOfMemoryError during Spark write to Snowflake stage',
     'spark.write.format("snowflake").option("dbtable","events").save()', 'FAILED',
     'RAW', 'EVENTS', DATEADD('HOURS', -4, CURRENT_TIMESTAMP())),

    ('fivetran_postgres_sync', 'FIVETRAN',
     'SSL certificate verification failed for source database pg-prod-replica.internal:5432',
     'SYNC postgres.users -> RAW.POSTGRES_USERS', 'FAILED',
     'RAW', 'POSTGRES', DATEADD('MINUTES', -10, CURRENT_TIMESTAMP()));

-- ============================================================================
-- SECTION 11: DEMO ERRORS (intentional failures for testing)
-- ============================================================================

CREATE OR REPLACE TABLE OPS_AI_MONITOR.DEMO_ERRORS.DT_SOURCE (ID INT, NAME VARCHAR);
INSERT INTO OPS_AI_MONITOR.DEMO_ERRORS.DT_SOURCE VALUES (1, 'test');

CREATE OR REPLACE TASK OPS_AI_MONITOR.DEMO_ERRORS.TSK_DEMO_FAIL
    WAREHOUSE = OPS_MONITOR_WH
    SCHEDULE = '1 MINUTE'
    SUSPEND_TASK_AFTER_NUM_FAILURES = 1
    COMMENT = 'Demo task that intentionally fails'
AS
    SELECT * FROM OPS_AI_MONITOR.DEMO_ERRORS.TABLE_THAT_DOES_NOT_EXIST_DEMO;

ALTER TASK OPS_AI_MONITOR.DEMO_ERRORS.TSK_DEMO_FAIL RESUME;

CREATE OR REPLACE PROCEDURE OPS_AI_MONITOR.DEMO_ERRORS.SP_DEMO_FAIL()
RETURNS VARCHAR
LANGUAGE SQL
AS
BEGIN
    SELECT * FROM OPS_AI_MONITOR.DEMO_ERRORS.NONEXISTENT_TABLE_FOR_SP_DEMO;
END;

CALL OPS_AI_MONITOR.DEMO_ERRORS.SP_DEMO_FAIL();

CREATE OR REPLACE FUNCTION OPS_AI_MONITOR.DEMO_ERRORS.FN_DEMO_FAIL(X INT)
RETURNS INT
LANGUAGE SQL
AS 'X / 0';

SELECT OPS_AI_MONITOR.DEMO_ERRORS.FN_DEMO_FAIL(42);

CREATE OR REPLACE DYNAMIC TABLE OPS_AI_MONITOR.DEMO_ERRORS.DT_DEMO_FAIL
    WAREHOUSE = OPS_MONITOR_WH
    TARGET_LAG = '1 MINUTE'
AS
    SELECT ID, NAME, ID / (ID - 1) AS BAD_CALC FROM OPS_AI_MONITOR.DEMO_ERRORS.DT_SOURCE;

CREATE OR REPLACE STREAM OPS_AI_MONITOR.DEMO_ERRORS.STR_DEMO
    ON TABLE OPS_AI_MONITOR.DEMO_ERRORS.DT_SOURCE;

SELECT NONEXISTENT_COL FROM OPS_AI_MONITOR.DEMO_ERRORS.STR_DEMO;

INSERT INTO OPS_AI_MONITOR.EVENT_LOGS.STALE_STREAMS (STREAM_NAME, DATABASE_NAME, SCHEMA_NAME)
VALUES ('DEMO_STALE_STREAM', 'PRODUCTION_DB', 'RAW_DATA');

COPY INTO OPS_AI_MONITOR.DEMO_ERRORS.DT_SOURCE
FROM @OPS_AI_MONITOR.DEMO_ERRORS.NONEXISTENT_STAGE_DEMO/data.csv
FILE_FORMAT = (TYPE = 'CSV');

SELECT * FROM OPS_AI_MONITOR.DEMO_ERRORS.CUSTOMERS_THAT_DO_NOT_EXIST;
SELEC * FORM OPS_AI_MONITOR.DEMO_ERRORS.DT_SOURCE WHER ID = 1;
SELECT 100 / 0 AS DEMO_DIVISION_ERROR;
SELECT TO_NUMBER('not_a_number_demo') AS BAD_CAST;

-- ============================================================================
-- SECTION 12: VERIFICATION QUERIES
-- ============================================================================

SHOW TASKS IN SCHEMA OPS_AI_MONITOR.EVENT_LOGS;

SELECT NAME, STATE, PREDECESSORS
FROM TABLE(OPS_AI_MONITOR.INFORMATION_SCHEMA.TASK_DEPENDENTS(
    TASK_NAME => 'OPS_AI_MONITOR.EVENT_LOGS.TSK_INGEST_FAILURES',
    RECURSIVE => TRUE
));

SELECT PIPELINE_TYPE, ERROR_CATEGORY, SEVERITY, COUNT(*) AS CNT
FROM OPS_AI_MONITOR.AI_ENGINE.V_FAILURE_INSIGHTS_ENRICHED
GROUP BY PIPELINE_TYPE, ERROR_CATEGORY, SEVERITY
ORDER BY PIPELINE_TYPE, CNT DESC;

SELECT * FROM OPS_AI_MONITOR.AI_ENGINE.V_FAILURE_METRICS;
SELECT * FROM OPS_AI_MONITOR.AI_ENGINE.V_SLA_SUMMARY;
SELECT * FROM OPS_AI_MONITOR.AI_ENGINE.V_CRITICAL_ALERTS LIMIT 10;

SELECT COUNT(*) AS TOTAL_FAILURES FROM OPS_AI_MONITOR.EVENT_LOGS.FAILURE_EVENTS;
SELECT COUNT(*) AS AI_ANALYZED FROM OPS_AI_MONITOR.AI_ENGINE.ERROR_ANALYSIS WHERE STATUS = 'SUCCESS';
SELECT COUNT(*) AS KB_PATTERNS FROM OPS_AI_MONITOR.METADATA.ERROR_KB;
SELECT COUNT(*) AS PENDING FROM OPS_AI_MONITOR.AI_ENGINE.V_AI_QUEUE;
SELECT COUNT(*) AS ALERTS_SENT FROM OPS_AI_MONITOR.AI_ENGINE.ALERT_LOG;
SELECT COUNT(*) AS AUTO_FIXES FROM OPS_AI_MONITOR.AI_ENGINE.AUTO_FIX_LOGS;



