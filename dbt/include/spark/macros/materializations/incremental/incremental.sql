{% materialization incremental, adapter='spark' -%}

  {#-- Validate early so we don't run SQL if the file_format + strategy combo is invalid --#}
  {%- set raw_file_format = config.get('file_format', default='parquet') -%}
  {%- set raw_strategy = config.get('incremental_strategy', default='append') -%}
  {%- set file_format = dbt_spark_validate_get_file_format(raw_file_format) -%}
  {%- set strategy = dbt_spark_validate_get_incremental_strategy(raw_strategy, file_format) -%}

  {#-- Set vars --#}
  {%- set unique_key = config.get('unique_key', none) -%}
  {%- set partition_by = config.get('partition_by', none) -%}  
  {%- set language = config.get('language') -%}
  {%- set on_schema_change = incremental_validate_on_schema_change(config.get('on_schema_change'), default='ignore') -%}
  {%- set target_relation = this -%}
  {%- set existing_relation = load_relation(this) -%}
  {%- set tmp_relation = make_temp_relation(this) -%}
  {%- set model_code = sql -%}

  {#-- Set Overwrite Mode --#}
  {%- if strategy == 'insert_overwrite' and partition_by -%}
    {%- call statement() -%}
      set spark.sql.sources.partitionOverwriteMode = DYNAMIC
    {%- endcall -%}
  {%- endif -%}

  {#-- Run pre-hooks --#}
  {{ run_hooks(pre_hooks) }}

  {#-- Incremental run logic --#}
  {%- if existing_relation is none -%}
    {#-- Relation must be created --#}
    {{log("make rel")}}
    {%- call statement('main', language=language) -%}
      {{ create_table_as(False, target_relation, model_code, language) }}
    {%- endcall -%}
  {%- elif existing_relation.is_view or should_full_refresh() -%}
    {#-- Relation must be dropped & recreated --#}
    {{log("remake rel")}}
    {%- do adapter.drop_relation(existing_relation) -%}
    {%- call statement('main', language=language) -%}
      {{ create_table_as(False, target_relation, model_code, language) }}
    {%- endcall -%}
  {%- else -%}
    {#-- Relation must be merged --#}
    {{log("merge rel")}}
    {%- call statement('create_tmp_relation', language=language) -%}
      {{ create_table_as(True, tmp_relation, model_code, language) }}
    {%- endcall -%}
    {%- do process_schema_changes(on_schema_change, tmp_relation, existing_relation) -%}
    {%- call statement('main') -%}
      {{ dbt_spark_get_incremental_sql(strategy, tmp_relation, target_relation, unique_key) }}
    {%- endcall -%}
    {%- if language == 'python' -%}
      {#--
      This is yucky.  
      See note in dbt-spark/dbt/include/spark/macros/adapters.sql
      re: python models and temporary views.

      Also, why doesn't either drop_relation or adapter.drop_relation work here?!
      --#}
      {% call statement('drop_relation') -%}
        drop table if exists {{ tmp_relation }}
      {%- endcall %}
    {%- endif -%}
  {%- endif -%}
  
  {{ log("Inc logic complete") }}
  
  {% do persist_docs(target_relation, model) %}
  
  {{ run_hooks(post_hooks) }}

  {{ return({'relations': [target_relation]}) }}

{%- endmaterialization %}
