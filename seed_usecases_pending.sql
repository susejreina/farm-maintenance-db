-- ============================================================
-- seed_usecases_pending.sql (fixed JSON quoting)
-- Use-case seeds (PENDING ONLY): creates tasks, plans, and rules,
-- and adjusts readings/dates so items appear as "due now".
-- Does NOT insert maintenance logs.
-- Prereqs: schema.sql, seed_catalogs.sql, seed_reference.sql
-- ============================================================

BEGIN;

-- 1) TASKS (idempotent by code)
-- ENGINE_OIL_CHANGE (targets engine oil filter component type)
INSERT INTO maintenance_tasks (code, name, description, component_type_id, default_parts)
SELECT
  'ENGINE_OIL_CHANGE' as code, 'Change Engine Oil' as name, 'Drain and replace oil; replace oil filter' as description,
  ct.id as component_type_id, $json$[{"sku":"JD-ENG-OIL-FLT-15","qty":1}]$json$::jsonb as default_parts
FROM component_types ct
WHERE ct.name = 'engine_oil_filter'
ON CONFLICT (code) DO NOTHING;

-- Weekly safety check (not used in due calculations here; kept as catalog example)
INSERT INTO maintenance_tasks (code, name, description)
VALUES ('WEEKLY_SAFETY_CHECK', 'Weekly Safety Inspection', 'General weekly safety checklist')
ON CONFLICT (code) DO NOTHING;

-- CABIN_AIR_FILTER_REPLACE (targets cabin air filter component type)
INSERT INTO maintenance_tasks (code, name, description, component_type_id, default_parts)
SELECT
  'CABIN_AIR_FILTER_REPLACE' as code, 'Replace Cabin Air Filter' as name, 'Replace cabin air filter element' as description,
  ct.id as component_type_id, $json$[{"sku":"CAF-200","qty":1}]$json$::jsonb as default_parts
FROM component_types ct
WHERE ct.name = 'cabin_air_filter'
ON CONFLICT (code) DO NOTHING;

-- 2) PLANS + RULES
-- 2A) MODEL plan: JD 8R 370 → ENGINE_OIL_CHANGE with 250h OR 12 months
WITH model AS (
  SELECT em.id AS model_id
  FROM equipment_models em
  JOIN manufacturers m ON m.id = em.manufacturer_id
  WHERE em.name='8R 370' AND m.name='John Deere'
), task AS (
  SELECT id AS task_id FROM maintenance_tasks WHERE code='ENGINE_OIL_CHANGE'
)
INSERT INTO maintenance_plans (task_id, scope_level, equipment_model_id, is_active, notes)
SELECT task.task_id, 'MODEL', model.model_id, TRUE, 'Default JD 8R oil change (250h OR 12 months)'
FROM model, task
WHERE NOT EXISTS (
  SELECT 1 FROM maintenance_plans mp
  WHERE mp.task_id = task.task_id AND mp.scope_level='MODEL' AND mp.equipment_model_id = model.model_id
);

-- USAGE rule: 250h
INSERT INTO schedule_rules (plan_id, kind, usage_counter_id, usage_every_value, reset_policy, is_active)
SELECT mp.id, 'USAGE', ct.id, 250.0, 'TASK_COMPLETION', TRUE
FROM maintenance_plans mp
JOIN maintenance_tasks t ON t.id = mp.task_id AND t.code='ENGINE_OIL_CHANGE'
JOIN counter_types ct ON ct.name='engine_hours'
JOIN equipment_models em ON em.id = mp.equipment_model_id
JOIN manufacturers m ON m.id = em.manufacturer_id
WHERE mp.scope_level='MODEL' AND em.name='8R 370' AND m.name='John Deere'
  AND NOT EXISTS (
    SELECT 1 FROM schedule_rules sr
    WHERE sr.plan_id = mp.id AND sr.kind='USAGE' AND sr.usage_every_value=250.0
  );

-- TIME rule: 12 months
INSERT INTO schedule_rules (plan_id, kind, time_every_n, time_unit, reset_policy, is_active)
SELECT mp.id, 'TIME', 12, 'month', 'TASK_COMPLETION', TRUE
FROM maintenance_plans mp
JOIN maintenance_tasks t ON t.id = mp.task_id AND t.code='ENGINE_OIL_CHANGE'
JOIN equipment_models em ON em.id = mp.equipment_model_id
JOIN manufacturers m ON m.id = em.manufacturer_id
WHERE mp.scope_level='MODEL' AND em.name='8R 370' AND m.name='John Deere'
  AND NOT EXISTS (
    SELECT 1 FROM schedule_rules sr
    WHERE sr.plan_id = mp.id AND sr.kind='TIME' AND sr.time_every_n=12 AND sr.time_unit='month'
  );

-- 2B) EQUIPMENT plan (override): Tractor A → ENGINE_OIL_CHANGE at 200h
WITH eq AS (
  SELECT id AS equipment_id FROM equipment WHERE name='Tractor A'
), task AS (
  SELECT id AS task_id FROM maintenance_tasks WHERE code='ENGINE_OIL_CHANGE'
)
INSERT INTO maintenance_plans (task_id, scope_level, equipment_id, is_active, notes)
SELECT task.task_id, 'EQUIPMENT', eq.equipment_id, TRUE, 'Override: aftermarket oil filter, 200h'
FROM eq, task
WHERE NOT EXISTS (
  SELECT 1 FROM maintenance_plans mp
  WHERE mp.task_id = task.task_id AND mp.scope_level='EQUIPMENT' AND mp.equipment_id = eq.equipment_id
);

INSERT INTO schedule_rules (plan_id, kind, usage_counter_id, usage_every_value, reset_policy, is_active)
SELECT mp.id, 'USAGE', ct.id, 200.0, 'TASK_COMPLETION', TRUE
FROM maintenance_plans mp
JOIN maintenance_tasks t ON t.id = mp.task_id AND t.code='ENGINE_OIL_CHANGE'
JOIN counter_types ct ON ct.name='engine_hours'
JOIN equipment e ON e.id = mp.equipment_id AND e.name='Tractor A'
WHERE mp.scope_level='EQUIPMENT'
  AND NOT EXISTS (
    SELECT 1 FROM schedule_rules sr
    WHERE sr.plan_id = mp.id AND sr.kind='USAGE' AND sr.usage_every_value=200.0
  );

-- 2C) COMPONENT_INSTANCE plan: Combine X → CABIN_AIR_FILTER_REPLACE every 6 months (reset on replacement)
WITH comp AS (
  SELECT ec.id AS equipment_component_id
  FROM equipment_components ec
  JOIN equipment e ON e.id = ec.equipment_id
  JOIN component_types ct ON ct.id = ec.component_type_id
  WHERE e.name='Combine X' AND ct.name = 'cabin air filter'
), task AS (
  SELECT id AS task_id FROM maintenance_tasks WHERE code='CABIN_AIR_FILTER_REPLACE'
)
INSERT INTO maintenance_plans (task_id, scope_level, equipment_component_id, is_active, notes)
SELECT task.task_id, 'COMPONENT_INSTANCE', comp.equipment_component_id, TRUE, 'Combine X cabin filter @6 months'
FROM comp, task
WHERE NOT EXISTS (
  SELECT 1 FROM maintenance_plans mp
  WHERE mp.task_id = task.task_id
    AND mp.scope_level='COMPONENT_INSTANCE'
    AND mp.equipment_component_id = comp.equipment_component_id
);

INSERT INTO schedule_rules (plan_id, kind, time_every_n, time_unit, reset_policy, is_active)
SELECT mp.id, 'TIME', 6, 'month', 'PART_REPLACEMENT', TRUE
FROM maintenance_plans mp
JOIN maintenance_tasks t ON t.id = mp.task_id AND t.code='CABIN_AIR_FILTER_REPLACE'
JOIN equipment_components ec ON ec.id = mp.equipment_component_id
WHERE NOT EXISTS (
  SELECT 1 FROM schedule_rules sr
  WHERE sr.plan_id = mp.id AND sr.kind='TIME' AND sr.time_every_n=6 AND sr.time_unit='month'
);

-- 3) ADJUSTMENTS SO THEY SHOW AS "DUE NOW"

-- 3A) Tractor A: current engine_hours > 200 (e.g., 210)
INSERT INTO meter_readings (meter_id, reading_value, reading_at, source)
SELECT em.id, 210.0, NOW(), 'seed_pending'
FROM equipment_meters em
JOIN equipment e ON e.id = em.equipment_id AND e.name='Tractor A'
JOIN counter_types ct ON ct.id = em.meter_kind_id AND ct.name='engine_hours';

-- 3B) Combine X: cabin filter installed_at → 8 months ago (so 6-month rule is overdue)
UPDATE equipment_components ec
SET installed_at = NOW() - INTERVAL '8 months'
FROM equipment e, component_types ct
WHERE ec.equipment_id = e.id
  AND e.name='Combine X'
  AND ct.id = ec.component_type_id
  AND ct.name = 'cabin air filter';

-- 3C) (Optional) Create Tractor B (same model) to illustrate "whichever comes first" by TIME
--     No equipment override. Low usage (<250h) but age >12 months ⇒ due by TIME.
DO $$
DECLARE
  v_model_id BIGINT;
  v_farm_id  BIGINT;
  v_exists   INT;
  v_eq_id    BIGINT;
  v_meter_id BIGINT;
BEGIN
  SELECT em.id INTO v_model_id
  FROM equipment_models em
  JOIN manufacturers m ON m.id = em.manufacturer_id
  WHERE em.name='8R 370' AND m.name='John Deere';

  SELECT id INTO v_farm_id FROM farms WHERE name='Sunny Acres';

  SELECT COUNT(*) INTO v_exists FROM equipment WHERE name='Tractor B';
  IF v_exists = 0 THEN
    INSERT INTO equipment (model_id, farm_id, name, serial_number, in_service_on, location_label)
    VALUES (v_model_id, v_farm_id, 'Tractor B', 'JD-8R-370-002', DATE '2023-01-01', 'North Shed')
    RETURNING id INTO v_eq_id;

    -- engine_hours meter
    INSERT INTO equipment_meters (equipment_id, meter_kind_id, label)
    SELECT v_eq_id, ct.id, 'Engine Hours'
    FROM counter_types ct WHERE ct.name='engine_hours'
    RETURNING id INTO v_meter_id;

    -- low reading (130h) today
    INSERT INTO meter_readings (meter_id, reading_value, reading_at, source)
    VALUES (v_meter_id, 130.0, NOW(), 'seed_pending');
  END IF;
END$$;

COMMIT;
