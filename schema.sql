
-- ============================================================
-- FarmerTitan — Maintenance Scheduling Database (PostgreSQL 15)
-- Supabase-ready (uses pgcrypto for UUIDs)
--
-- Conventions:
-- - Audit columns (created_at/updated_at/created_by/updated_by) are present and user IDs are OPTIONAL (NULL allowed).
-- - Timestamps are UTC with second precision (timestamptz(0)).
-- - Units: usage rules inherit units from counter_types.default_unit.
-- - Scope specificity: COMPONENT_INSTANCE > EQUIPMENT > MODEL (resolved by application).
-- ============================================================

-- ------------------------------------------------------------
-- Extensions
-- ------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================
-- ENUMS
-- ============================================================

-- ------------------------------------------------------------
-- interval_unit: mixed time and usage units (document usage per rule)
-- ------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'interval_unit') THEN
    CREATE TYPE interval_unit AS ENUM ('hour','km','mile','day','week','month','year','acre','cycle');
  END IF;
END$$;

-- ------------------------------------------------------------
-- plan_scope: where the plan applies
-- ------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'plan_scope') THEN
    CREATE TYPE plan_scope AS ENUM ('MODEL','EQUIPMENT','COMPONENT_INSTANCE');
  END IF;
END$$;

-- ------------------------------------------------------------
-- schedule_kind: rule category
-- ------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'schedule_kind') THEN
    CREATE TYPE schedule_kind AS ENUM ('USAGE','TIME','RRULE','EVENT');
  END IF;
END$$;

-- ------------------------------------------------------------
-- reset_policy: baseline reset behavior
-- ------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'reset_policy') THEN
    CREATE TYPE reset_policy AS ENUM ('TASK_COMPLETION','PART_REPLACEMENT','NEVER');
  END IF;
END$$;

-- ============================================================
-- CATALOGS
-- (manufacturers, equipment_types, counter_types, component_types, part_catalog)
-- ============================================================

-- ------------------------------------------------------------
-- counter_types: catalog of usage counters (engine_hours, odometer, acres, cycles)
-- ------------------------------------------------------------
CREATE TABLE counter_types (
  id            BIGSERIAL PRIMARY KEY,
  name          TEXT NOT NULL UNIQUE,            -- canonical key (e.g., 'engine_hours')
  description   TEXT,
  default_unit  interval_unit NOT NULL,          -- e.g., 'hour','km','acre','cycle'
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ(0) NOT NULL DEFAULT date_trunc('second', now()),
  created_by    UUID,
  updated_at    TIMESTAMPTZ(0),
  updated_by    UUID
);
CREATE INDEX IF NOT EXISTS idx_counter_types_active ON counter_types(is_active);

-- ------------------------------------------------------------
-- equipment_types: catalog of equipment categories (tractor, combine, ...)
-- ------------------------------------------------------------
CREATE TABLE equipment_types (
  id          BIGSERIAL PRIMARY KEY,
  name        TEXT NOT NULL UNIQUE,
  description TEXT,
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ(0) NOT NULL DEFAULT date_trunc('second', now()),
  created_by  UUID,
  updated_at  TIMESTAMPTZ(0),
  updated_by  UUID
);
CREATE INDEX IF NOT EXISTS idx_equipment_types_active ON equipment_types(is_active);

-- ------------------------------------------------------------
-- manufacturers: catalog of equipment/part brands
-- ------------------------------------------------------------
CREATE TABLE manufacturers (
  id          BIGSERIAL PRIMARY KEY,
  name        TEXT NOT NULL UNIQUE,
  country     TEXT,                                -- free text; may be normalized elsewhere
  created_at  TIMESTAMPTZ(0) NOT NULL DEFAULT date_trunc('second', now()),
  created_by  UUID,
  updated_at  TIMESTAMPTZ(0),
  updated_by  UUID
);
CREATE INDEX IF NOT EXISTS idx_manufacturers_country ON manufacturers(country);

-- ------------------------------------------------------------
-- component_types: families of components/parts (oil filter, battery, ...)
-- ------------------------------------------------------------
CREATE TABLE component_types (
  id           BIGINT PRIMARY KEY,
  name         TEXT NOT NULL UNIQUE,
  description  TEXT,
  is_active    BOOLEAN NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ(0) NOT NULL DEFAULT date_trunc('second', now()),
  created_by   UUID,
  updated_at   TIMESTAMPTZ(0),
  updated_by   UUID
);
CREATE INDEX IF NOT EXISTS idx_component_types_active ON component_types(is_active);

-- ------------------------------------------------------------
-- part_catalog: concrete SKUs for components (OEM/aftermarket)
-- ------------------------------------------------------------
CREATE TABLE part_catalog (
  id                 BIGSERIAL PRIMARY KEY,
  component_type_id  BIGINT NOT NULL REFERENCES component_types(id),
  manufacturer_id    BIGINT REFERENCES manufacturers(id),
  sku                TEXT,
  name               TEXT NOT NULL,
  spec               JSONB,                            -- free-form attributes
  is_active          BOOLEAN NOT NULL DEFAULT TRUE,
  created_at         TIMESTAMPTZ(0) NOT NULL DEFAULT date_trunc('second', now()),
  created_by         UUID,
  updated_at         TIMESTAMPTZ(0),
  updated_by         UUID,
  UNIQUE (component_type_id, sku)
);
CREATE INDEX IF NOT EXISTS idx_part_component    ON part_catalog(component_type_id);
CREATE INDEX IF NOT EXISTS idx_part_manufacturer ON part_catalog(manufacturer_id);
CREATE INDEX IF NOT EXISTS idx_part_active       ON part_catalog(is_active);

-- ============================================================
-- FARMS & EQUIPMENT
-- (farms, equipment_models, equipment)
-- ============================================================

-- ------------------------------------------------------------
-- farms: customer boundary (public UUID; location as JSONB)
-- ------------------------------------------------------------
CREATE TABLE farms (
  id             BIGSERIAL PRIMARY KEY,
  uuid           UUID NOT NULL DEFAULT gen_random_uuid(),
  name           TEXT NOT NULL,
  description    TEXT,
  location       JSONB,
  created_at     TIMESTAMPTZ(0) NOT NULL DEFAULT date_trunc('second', now()),
  created_by     UUID,
  updated_at     TIMESTAMPTZ(0),
  updated_by     UUID,
  UNIQUE (uuid),
  UNIQUE (name)
);
CREATE INDEX IF NOT EXISTS idx_farms_name ON farms(name);

-- ------------------------------------------------------------
-- equipment_models: model catalog linking manufacturer & equipment_type
-- ------------------------------------------------------------
CREATE TABLE equipment_models (
  id                 BIGSERIAL PRIMARY KEY,
  manufacturer_id    BIGINT NOT NULL REFERENCES manufacturers(id),
  equipment_type_id  BIGINT NOT NULL REFERENCES equipment_types(id),
  name               TEXT NOT NULL,
  specs              JSONB,
  created_at         TIMESTAMPTZ(0) NOT NULL DEFAULT date_trunc('second', now()),
  created_by         UUID,
  updated_at         TIMESTAMPTZ(0),
  updated_by         UUID,
  UNIQUE (manufacturer_id, name)
);
CREATE INDEX IF NOT EXISTS idx_equipment_models_manu ON equipment_models(manufacturer_id);
CREATE INDEX IF NOT EXISTS idx_equipment_models_type ON equipment_models(equipment_type_id);

-- ------------------------------------------------------------
-- equipment: physical units in the fleet
-- ------------------------------------------------------------
CREATE TABLE equipment (
  id               BIGSERIAL PRIMARY KEY,
  model_id         BIGINT NOT NULL REFERENCES equipment_models(id),
  farm_id          BIGINT NOT NULL REFERENCES farms(id),
  name             TEXT,
  serial_number    TEXT,
  vin              TEXT,
  in_service_on    DATE NOT NULL,
  retired_on       DATE,
  location_label   TEXT,
  meta             JSONB,
  attention_flag   BOOLEAN NOT NULL DEFAULT FALSE,
  attention_reason TEXT,
  created_at       TIMESTAMPTZ(0) NOT NULL DEFAULT date_trunc('second', now()),
  created_by       UUID,
  updated_at       TIMESTAMPTZ(0),
  updated_by       UUID,
  UNIQUE (serial_number),
  CHECK (retired_on IS NULL OR retired_on >= in_service_on)
);
CREATE INDEX IF NOT EXISTS idx_equipment_model     ON equipment(model_id);
CREATE INDEX IF NOT EXISTS idx_equipment_farm      ON equipment(farm_id);
CREATE INDEX IF NOT EXISTS idx_equipment_retired   ON equipment(retired_on);
CREATE INDEX IF NOT EXISTS idx_equipment_attention ON equipment(attention_flag);

-- ============================================================
-- METERS & READINGS
-- (equipment_meters, meter_readings)
-- ============================================================

-- ------------------------------------------------------------
-- equipment_meters: logical/physical meters attached to an equipment
-- ------------------------------------------------------------
CREATE TABLE equipment_meters (
  id             BIGSERIAL PRIMARY KEY,
  equipment_id   BIGINT NOT NULL REFERENCES equipment(id),
  meter_kind_id  BIGINT NOT NULL REFERENCES counter_types(id), -- e.g., engine_hours, odometer_km
  label          TEXT,
  meta           JSONB,
  created_at     TIMESTAMPTZ(0) NOT NULL DEFAULT date_trunc('second', now()),
  created_by     UUID,
  updated_at     TIMESTAMPTZ(0),
  updated_by     UUID,
  UNIQUE (equipment_id, meter_kind_id)
);
CREATE INDEX IF NOT EXISTS idx_equipment_meters_equipment ON equipment_meters(equipment_id);
CREATE INDEX IF NOT EXISTS idx_equipment_meters_kind_id   ON equipment_meters(meter_kind_id);

-- ------------------------------------------------------------
-- meter_readings: point-in-time readings for meters
-- ------------------------------------------------------------
CREATE TABLE meter_readings (
  id             BIGSERIAL PRIMARY KEY,
  meter_id       BIGINT NOT NULL REFERENCES equipment_meters(id),
  reading_value  NUMERIC NOT NULL CHECK (reading_value >= 0),
  reading_at     TIMESTAMPTZ(0) NOT NULL,
  source         TEXT,
  meta           JSONB,
  created_at     TIMESTAMPTZ(0) NOT NULL DEFAULT date_trunc('second', now()),
  created_by     UUID,
  updated_at     TIMESTAMPTZ(0),
  updated_by     UUID,
  UNIQUE (meter_id, reading_at)
);
CREATE INDEX IF NOT EXISTS idx_meter_readings_meter ON meter_readings(meter_id);
CREATE INDEX IF NOT EXISTS idx_meter_readings_at    ON meter_readings(reading_at);

-- ============================================================
-- COMPONENTS & PARTS
-- (equipment_components)
-- ============================================================

-- ------------------------------------------------------------
-- equipment_components: installed component instances per equipment
-- ------------------------------------------------------------
CREATE TABLE equipment_components (
  id                 BIGSERIAL PRIMARY KEY,
  public_id          UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  equipment_id       BIGINT NOT NULL REFERENCES equipment(id),
  component_type_id  BIGINT NOT NULL REFERENCES component_types(id),
  part_id            BIGINT REFERENCES part_catalog(id),
  serial_number      TEXT,
  installed_at       TIMESTAMPTZ(0),
  removed_at         TIMESTAMPTZ(0),
  created_at         TIMESTAMPTZ(0) NOT NULL DEFAULT date_trunc('second', now()),
  created_by         UUID,
  updated_at         TIMESTAMPTZ(0),
  updated_by         UUID
);
CREATE INDEX IF NOT EXISTS idx_equipment_components_equipment ON equipment_components(equipment_id);
CREATE INDEX IF NOT EXISTS idx_equipment_components_type      ON equipment_components(component_type_id);
CREATE INDEX IF NOT EXISTS idx_equipment_components_part      ON equipment_components(part_id);

-- ============================================================
-- MAINTENANCE DOMAIN
-- (maintenance_tasks, maintenance_plans, schedule_rules, maintenance_logs)
-- ============================================================

-- ------------------------------------------------------------
-- maintenance_tasks: catalog of maintenance actions
-- ------------------------------------------------------------
CREATE TABLE maintenance_tasks (
  id                 BIGSERIAL PRIMARY KEY,
  code               TEXT UNIQUE,                       -- external stable key
  name               TEXT NOT NULL,
  description        TEXT,
  component_type_id  BIGINT REFERENCES component_types(id),
  default_parts      JSONB,                             -- e.g., list of SKUs/qty
  is_active          BOOLEAN NOT NULL DEFAULT TRUE,
  created_at         TIMESTAMPTZ(0) NOT NULL DEFAULT date_trunc('second', now()),
  created_by         UUID,
  updated_at         TIMESTAMPTZ(0),
  updated_by         UUID
);
CREATE INDEX IF NOT EXISTS idx_task_component_type ON maintenance_tasks(component_type_id);
CREATE INDEX IF NOT EXISTS idx_task_active         ON maintenance_tasks(is_active);

-- ------------------------------------------------------------
-- maintenance_plans: bind a task to a scope (MODEL / EQUIPMENT / COMPONENT_INSTANCE)
-- ------------------------------------------------------------
CREATE TABLE maintenance_plans (
  id                       BIGSERIAL PRIMARY KEY,
  task_id                  BIGINT NOT NULL REFERENCES maintenance_tasks(id),
  scope_level              plan_scope NOT NULL,
  equipment_model_id       BIGINT REFERENCES equipment_models(id),
  equipment_id             BIGINT REFERENCES equipment(id),
  equipment_component_id   BIGINT REFERENCES equipment_components(id),
  is_active                BOOLEAN NOT NULL DEFAULT TRUE,
  notes                    TEXT,
  created_at               TIMESTAMPTZ(0) NOT NULL DEFAULT date_trunc('second', now()),
  created_by               UUID,
  updated_at               TIMESTAMPTZ(0),
  updated_by               UUID,
  CHECK (
    (scope_level = 'MODEL'              AND equipment_model_id     IS NOT NULL AND equipment_id IS NULL AND equipment_component_id IS NULL) OR
    (scope_level = 'EQUIPMENT'          AND equipment_id           IS NOT NULL AND equipment_model_id IS NULL AND equipment_component_id IS NULL) OR
    (scope_level = 'COMPONENT_INSTANCE' AND equipment_component_id IS NOT NULL AND equipment_model_id IS NULL AND equipment_id IS NULL)
  )
);
CREATE INDEX IF NOT EXISTS idx_mplan_task            ON maintenance_plans(task_id);
CREATE INDEX IF NOT EXISTS idx_mplan_scope_model     ON maintenance_plans(scope_level, equipment_model_id);
CREATE INDEX IF NOT EXISTS idx_mplan_scope_equipment ON maintenance_plans(scope_level, equipment_id);
CREATE INDEX IF NOT EXISTS idx_mplan_scope_component ON maintenance_plans(scope_level, equipment_component_id);
CREATE INDEX IF NOT EXISTS idx_mplan_active          ON maintenance_plans(is_active);

-- ------------------------------------------------------------
-- schedule_rules: frequency/condition rules per maintenance plan
-- ------------------------------------------------------------
CREATE TABLE schedule_rules (
  id                  BIGSERIAL PRIMARY KEY,
  plan_id             BIGINT NOT NULL REFERENCES maintenance_plans(id) ON DELETE CASCADE,
  kind                schedule_kind NOT NULL,               -- 'USAGE' | 'TIME' | 'RRULE' | 'EVENT'
  -- USAGE
  usage_counter_id    BIGINT REFERENCES counter_types(id),
  usage_every_value   NUMERIC(18,3),
  -- TIME
  time_every_n        INT,
  time_unit           interval_unit,
  -- RRULE
  rrule               TEXT,
  tzid                TEXT,
  -- General
  starts_at           TIMESTAMPTZ(0),
  reset_policy        reset_policy NOT NULL DEFAULT 'TASK_COMPLETION',
  is_active           BOOLEAN NOT NULL DEFAULT TRUE,
  created_at          TIMESTAMPTZ(0) NOT NULL DEFAULT date_trunc('second', now()),
  created_by          UUID,
  updated_at          TIMESTAMPTZ(0),
  updated_by          UUID,
  CHECK (
    kind <> 'USAGE'
    OR (usage_counter_id IS NOT NULL AND usage_every_value IS NOT NULL)
  ),
  CHECK (
    kind <> 'TIME'
    OR (time_every_n IS NOT NULL AND time_every_n > 0 AND time_unit IN ('day','week','month','year'))
  ),
  CHECK (
    kind <> 'RRULE'
    OR (rrule IS NOT NULL AND tzid IS NOT NULL)
  )
);
CREATE INDEX IF NOT EXISTS idx_srule_plan   ON schedule_rules(plan_id);
CREATE INDEX IF NOT EXISTS idx_srule_kind   ON schedule_rules(kind);
CREATE INDEX IF NOT EXISTS idx_srule_active ON schedule_rules(is_active);

-- ------------------------------------------------------------
-- maintenance_logs: execution history of maintenance tasks
-- ------------------------------------------------------------
CREATE TABLE maintenance_logs (
  id                       BIGSERIAL PRIMARY KEY,
  equipment_id             BIGINT NOT NULL REFERENCES equipment(id),
  equipment_component_id   BIGINT REFERENCES equipment_components(id),
  task_id                  BIGINT NOT NULL REFERENCES maintenance_tasks(id),
  plan_id                  BIGINT REFERENCES maintenance_plans(id),
  performed_at             TIMESTAMPTZ(0) NOT NULL DEFAULT date_trunc('second', now()),
  usage_counter_id         BIGINT REFERENCES counter_types(id),
  usage_value_at_service   NUMERIC(18,3),
  performed_by             TEXT,
  notes                    TEXT,
  parts_used               JSONB,
  created_at               TIMESTAMPTZ(0) NOT NULL DEFAULT date_trunc('second', now()),
  created_by               UUID,
  updated_at               TIMESTAMPTZ(0),
  updated_by               UUID,
  CHECK (usage_value_at_service IS NULL OR usage_value_at_service >= 0),
  CHECK (usage_value_at_service IS NULL OR usage_counter_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_mlogs_equipment_time ON maintenance_logs(equipment_id, performed_at);
CREATE INDEX IF NOT EXISTS idx_mlogs_task_time      ON maintenance_logs(task_id, performed_at);
CREATE INDEX IF NOT EXISTS idx_mlogs_component_time ON maintenance_logs(equipment_component_id, performed_at);
CREATE INDEX IF NOT EXISTS idx_mlogs_plan           ON maintenance_logs(plan_id);
CREATE INDEX IF NOT EXISTS idx_mlogs_usage_counter  ON maintenance_logs(usage_counter_id);
