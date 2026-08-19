
/*
The next two lines allow 'pg_stat_statements_calls' information queried
by Prometheus/Grafana. This setting is aimed for performance
analysis. Comment these lines for Prod environments.
*/
CREATE EXTENSION pg_stat_statements;
alter system set shared_preload_libraries='pg_stat_statements';
