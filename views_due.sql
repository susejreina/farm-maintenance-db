-- ============================================
-- views_due.sql
-- Views to compute maintenance items that are DUE (pending to do).
-- Works with schema.sql + seed_* scripts provided.
-- ============================================

-- Drop in dependency order
DROP VIEW IF EXISTS v_maintenance_due_effective CASCADE;
DROP VIEW IF EXISTS v_maintenance_due_now CASCADE;
DROP VIEW IF EXISTS v_maintenance_due_simple CASCADE;

-- v_maintenance_due_simple: expands model plans to equipment, computes USAGE/TIME due
CREATE VIEW v_maintenance_due_simple AS
WITH plan_targets AS (
  SELECT
    mp.id                 AS plan_id,
    mp.task_id,
    mp.scope_level,
    mp.notes,
    CASE 
      WHEN mp.scope_level = 'EQUIPMENT'          THEN mp.equipment_id
      WHEN mp.scope_level = 'MODEL'              THEN e.id
      WHEN mp.scope_level = 'COMPONENT_INSTANCE' THEN ec.equipment_id
    END AS equipment_id,
    mp.equipment_component_id
  FROM maintenance_plans mp
  LEFT JOIN equipment e 
    ON mp.scope_level = 'MODEL' AND e.model_id = mp.equipment_model_id
  LEFT JOIN equipment_components ec
    ON mp.scope_level = 'COMPONENT_INSTANCE' AND ec.id = mp.equipment_component_id
  WHERE mp.is_active = TRUE
), latest_meters AS (
  -- last reading per (equipment, counter)
  SELECT em.equipment_id, em.meter_kind_id AS counter_id, mr.reading_value, mr.reading_at
  FROM equipment_meters em
  JOIN LATERAL (
    SELECT reading_value, reading_at
    FROM meter_readings mr
    WHERE mr.meter_id = em.id
    ORDER BY mr.reading_at DESC
    LIMIT 1
  ) mr ON TRUE
), usage_due AS (
  SELECT
    pt.plan_id,
    sr.id AS rule_id,
    'USAGE'::text AS rule_kind,
    pt.scope_level,
    pt.equipment_id,
    e.name AS equipment_name,
    pt.equipment_component_id,
    t.id AS task_id,
    t.code AS task_code,
    t.name AS task_name,
    ct.name AS counter_name,
    lm.reading_value AS current_usage_value,
    sr.usage_every_value,
    (sr.usage_every_value - COALESCE(lm.reading_value, 0)) AS remaining_to_due,
    NULL::timestamptz AS baseline_at,
    NULL::timestamptz AS next_due_at,
    (COALESCE(lm.reading_value, 0) >= sr.usage_every_value) AS due_now,
    pt.notes
  FROM plan_targets pt
  JOIN schedule_rules sr ON sr.plan_id = pt.plan_id AND sr.is_active = TRUE AND sr.kind = 'USAGE'
  JOIN equipment e ON e.id = pt.equipment_id AND e.retired_on IS NULL
  JOIN maintenance_tasks t ON t.id = pt.task_id
  JOIN counter_types ct ON ct.id = sr.usage_counter_id
  LEFT JOIN latest_meters lm ON lm.equipment_id = pt.equipment_id AND lm.counter_id = sr.usage_counter_id
), time_due AS (
  SELECT
    pt.plan_id,
    sr.id AS rule_id,
    'TIME'::text AS rule_kind,
    pt.scope_level,
    pt.equipment_id,
    e.name AS equipment_name,
    pt.equipment_component_id,
    t.id AS task_id,
    t.code AS task_code,
    t.name AS task_name,
    NULL::text AS counter_name,
    NULL::numeric AS current_usage_value,
    NULL::numeric AS usage_every_value,
    NULL::numeric AS remaining_to_due,
    -- baseline selection
    CASE 
      WHEN sr.reset_policy = 'PART_REPLACEMENT' AND pt.scope_level = 'COMPONENT_INSTANCE' 
        THEN COALESCE(sr.starts_at, ec.installed_at, e.in_service_on::timestamptz)
      ELSE COALESCE(sr.starts_at, e.in_service_on::timestamptz)
    END AS baseline_at,
    -- next_due_at based on time_unit
    CASE sr.time_unit
      WHEN 'day'   THEN COALESCE(sr.starts_at, CASE WHEN sr.reset_policy='PART_REPLACEMENT' AND pt.scope_level='COMPONENT_INSTANCE' THEN ec.installed_at ELSE e.in_service_on::timestamptz END) + make_interval(days   => sr.time_every_n)
      WHEN 'week'  THEN COALESCE(sr.starts_at, CASE WHEN sr.reset_policy='PART_REPLACEMENT' AND pt.scope_level='COMPONENT_INSTANCE' THEN ec.installed_at ELSE e.in_service_on::timestamptz END) + (sr.time_every_n || ' weeks')::interval
      WHEN 'month' THEN COALESCE(sr.starts_at, CASE WHEN sr.reset_policy='PART_REPLACEMENT' AND pt.scope_level='COMPONENT_INSTANCE' THEN ec.installed_at ELSE e.in_service_on::timestamptz END) + make_interval(months => sr.time_every_n)
      WHEN 'year'  THEN COALESCE(sr.starts_at, CASE WHEN sr.reset_policy='PART_REPLACEMENT' AND pt.scope_level='COMPONENT_INSTANCE' THEN ec.installed_at ELSE e.in_service_on::timestamptz END) + make_interval(years  => sr.time_every_n)
    END AS next_due_at,
    -- due when next_due_at <= now()
    (
      CASE sr.time_unit
        WHEN 'day'   THEN COALESCE(sr.starts_at, CASE WHEN sr.reset_policy='PART_REPLACEMENT' AND pt.scope_level='COMPONENT_INSTANCE' THEN ec.installed_at ELSE e.in_service_on::timestamptz END) + make_interval(days   => sr.time_every_n)
        WHEN 'week'  THEN COALESCE(sr.starts_at, CASE WHEN sr.reset_policy='PART_REPLACEMENT' AND pt.scope_level='COMPONENT_INSTANCE' THEN ec.installed_at ELSE e.in_service_on::timestamptz END) + (sr.time_every_n || ' weeks')::interval
        WHEN 'month' THEN COALESCE(sr.starts_at, CASE WHEN sr.reset_policy='PART_REPLACEMENT' AND pt.scope_level='COMPONENT_INSTANCE' THEN ec.installed_at ELSE e.in_service_on::timestamptz END) + make_interval(months => sr.time_every_n)
        WHEN 'year'  THEN COALESCE(sr.starts_at, CASE WHEN sr.reset_policy='PART_REPLACEMENT' AND pt.scope_level='COMPONENT_INSTANCE' THEN ec.installed_at ELSE e.in_service_on::timestamptz END) + make_interval(years  => sr.time_every_n)
      END <= now()
    ) AS due_now,
    pt.notes
  FROM plan_targets pt
  JOIN schedule_rules sr ON sr.plan_id = pt.plan_id AND sr.is_active = TRUE AND sr.kind = 'TIME'
  JOIN equipment e ON e.id = pt.equipment_id AND e.retired_on IS NULL
  JOIN maintenance_tasks t ON t.id = pt.task_id
  LEFT JOIN equipment_components ec ON ec.id = pt.equipment_component_id
)
SELECT * FROM usage_due
UNION ALL
SELECT * FROM time_due
;

-- v_maintenance_due_now: only overdue
CREATE VIEW v_maintenance_due_now AS
SELECT *
FROM v_maintenance_due_simple
WHERE due_now = TRUE;

-- v_maintenance_due_effective: precedence COMPONENT_INSTANCE > EQUIPMENT > MODEL
CREATE VIEW v_maintenance_due_effective AS
WITH ranked AS (
  SELECT
    v.*,
    CASE v.scope_level
      WHEN 'COMPONENT_INSTANCE' THEN 1
      WHEN 'EQUIPMENT'          THEN 2
      WHEN 'MODEL'              THEN 3
      ELSE 9
    END AS scope_rank,
    row_number() OVER (
      PARTITION BY v.equipment_id, v.task_id
      ORDER BY 
        CASE v.scope_level
          WHEN 'COMPONENT_INSTANCE' THEN 1
          WHEN 'EQUIPMENT'          THEN 2
          WHEN 'MODEL'              THEN 3
          ELSE 9
        END,
        COALESCE(v.next_due_at, now()) ASC
    ) AS rn
  FROM v_maintenance_due_now v
)
SELECT *
FROM ranked
WHERE rn = 1;
