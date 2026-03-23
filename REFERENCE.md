# Error Patterns Reference

## Common Errors

### Missing Object
Error: "does not exist"
Fix:
CREATE TABLE <table_name> (...);

### Permission Issue
Error: "not authorized"
Fix:
GRANT SELECT ON TABLE <table> TO ROLE <role>;

### Division by Zero
Fix:
SELECT col1 / NULLIF(col2, 0)

### Warehouse Suspended
Fix:
ALTER WAREHOUSE <wh> RESUME;