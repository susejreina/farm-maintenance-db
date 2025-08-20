
-- ============================================
-- seed_catalogs.sql
-- Core catalogs: equipment_types, counter_types, component_types
-- Safe to rerun.
-- ============================================

-- Clean (optional for idempotency)
TRUNCATE TABLE equipment_types RESTART IDENTITY CASCADE;
TRUNCATE TABLE counter_types RESTART IDENTITY CASCADE;
TRUNCATE TABLE component_types CASCADE;  -- no identity column; keep explicit IDs below

-- Equipment Types
INSERT INTO equipment_types (name, description)
VALUES
  ('tractor', 'Agricultural tractor'),
  ('combine', 'Combine harvester'),
  ('sprayer', 'Self-propelled sprayer'),
  ('seeder',  'Planter/Seeder'),
  ('baler',   'Baler');

-- Counter Types (note: default_unit must be in interval_unit enum)
INSERT INTO counter_types (name, description, default_unit)
VALUES
  ('engine_hours',     'Primary engine runtime counter', 'hour'),
  ('attachment_hours', 'Runtime for auxiliary/attachment implements', 'hour'),
  ('odometer_km',      'Vehicle odometer in kilometers', 'km'),
  ('acres_processed',  'Area processed by implements', 'acre');

-- Component Types (explicit IDs to keep stable keys for seeds & references)
-- id: 1..N are reserved in this seed for common families
INSERT INTO component_types (id, name, description) VALUES
  (1, 'engine',               'Engine assembly'),
  (2, 'hydraulic_filter',     'Hydraulic filter element'),
  (3, 'cabin_air_filter',     'Cabin air filter element'),
  (4, 'battery',              'Starter battery / electrical'),
  (5, 'engine_oil_filter',    'Engine oil filter element'),
  (6, 'belt',                 'Drive/auxiliary belts');
