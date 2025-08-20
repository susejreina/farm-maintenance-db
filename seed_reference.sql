-- ============================================
-- seed_reference.sql (corrected)
-- Example reference data: farms, manufacturers, models, equipment,
-- parts, components, meters, and initial readings.
-- Safe to rerun on a fresh DB (uses TRUNCATE). Assumes seed_catalogs.sql ran first.
-- ============================================

-- Clean (optional; order matters due to FKs)
TRUNCATE TABLE meter_readings RESTART IDENTITY CASCADE;
TRUNCATE TABLE equipment_meters RESTART IDENTITY CASCADE;
TRUNCATE TABLE equipment_components RESTART IDENTITY CASCADE;
TRUNCATE TABLE part_catalog RESTART IDENTITY CASCADE;
TRUNCATE TABLE equipment RESTART IDENTITY CASCADE;
TRUNCATE TABLE equipment_models RESTART IDENTITY CASCADE;
TRUNCATE TABLE manufacturers RESTART IDENTITY CASCADE;
TRUNCATE TABLE farms RESTART IDENTITY CASCADE;

-- Farms
INSERT INTO farms (name, description, location)
VALUES
  ('Sunny Acres', 'Demo farm used for validation', '{"country":"US","lat":41.9,"lon":-93.6}'::jsonb);

-- Manufacturers
INSERT INTO manufacturers (name, country) VALUES
  ('John Deere', 'US'),
  ('Case IH',    'US');

-- Equipment Models
-- John Deere 8R 370 (tractor)
INSERT INTO equipment_models (manufacturer_id, equipment_type_id, name, specs)
SELECT m.id, et.id, '8R 370', '{"horsepower":370, "series":"8R"}'::jsonb
FROM manufacturers m
JOIN equipment_types et ON et.name='tractor'
WHERE m.name='John Deere';

-- Case IH Axial-Flow 8250 (combine)
INSERT INTO equipment_models (manufacturer_id, equipment_type_id, name, specs)
SELECT m.id, et.id, 'Axial-Flow 8250', '{"class":9, "series":"Axial-Flow"}'::jsonb
FROM manufacturers m
JOIN equipment_types et ON et.name='combine'
WHERE m.name='Case IH';

-- Equipment Units
-- Tractor A (JD 8R 370) @ Sunny Acres
INSERT INTO equipment (model_id, farm_id, name, serial_number, in_service_on, location_label, meta)
SELECT em.id, f.id, 'Tractor A', 'JD-8R-370-001', DATE '2023-03-01', 'North Shed', '{"notes":"primary tillage"}'::jsonb
FROM equipment_models em
JOIN manufacturers m ON m.id = em.manufacturer_id
JOIN farms f ON f.name = 'Sunny Acres'
WHERE em.name='8R 370' AND m.name='John Deere';

-- Combine X (Case IH 8250) @ Sunny Acres
INSERT INTO equipment (model_id, farm_id, name, serial_number, in_service_on, location_label)
SELECT em.id, f.id, 'Combine X', 'CIH-8250-001', DATE '2023-06-15', 'South Barn'
FROM equipment_models em
JOIN manufacturers m ON m.id = em.manufacturer_id
JOIN farms f ON f.name = 'Sunny Acres'
WHERE em.name='Axial-Flow 8250' AND m.name='Case IH';

-- Parts (Catalog)
-- Engine oil filter for John Deere tractor
INSERT INTO part_catalog (component_type_id, manufacturer_id, sku, name, spec)
SELECT ct.id as component_type_id, m.id as manufacturer_id, 'JD-ENG-OIL-FLT-15' as sku, 'JD Engine Oil Filter 15' as name, '{"micron":10,"rating":"OEM"}'::jsonb as spec
FROM component_types ct
JOIN manufacturers m ON m.name='John Deere'
WHERE ct.name='engine_oil_filter';

-- Cabin air filter (generic/no-brand)
INSERT INTO part_catalog (component_type_id, sku, name, spec)
SELECT ct.id as component_type_id, 'CAF-200' as sku, 'Cabin Air Filter CAF-200' as name, '{"size":"standard"}'::jsonb as spec
FROM component_types ct
WHERE ct.name='cabin_air_filter';

-- Installed Components (Equipment Components)
-- Install oil filter on Tractor A
INSERT INTO equipment_components (equipment_id, component_type_id, part_id, serial_number, installed_at)
SELECT e.id as equipment_id, ct.id as component_type_id, p.id, 'OF-TR-A-001', NOW()
FROM equipment e
JOIN component_types ct ON ct.name='engine_oil_filter'
JOIN part_catalog p ON p.sku='JD-ENG-OIL-FLT-15' AND p.component_type_id = ct.id
WHERE e.name='Tractor A';

-- Install cabin air filter on Combine X
INSERT INTO equipment_components (equipment_id, component_type_id, part_id, serial_number, installed_at)
SELECT e.id as equipment_id, ct.id as component_type_id, p.id, 'CAF-CX-001', NOW()
FROM equipment e
JOIN component_types ct ON ct.name='cabin_air_filter'
JOIN part_catalog p ON p.sku='CAF-200' AND p.component_type_id = ct.id
WHERE e.name='Combine X';

-- Meters
-- Tractor A: engine_hours + odometer_km
INSERT INTO equipment_meters (equipment_id, meter_kind_id, label)
SELECT e.id, ct.id, 'Engine Hours'
FROM equipment e
JOIN counter_types ct ON ct.name='engine_hours'
WHERE e.name='Tractor A';

INSERT INTO equipment_meters (equipment_id, meter_kind_id, label)
SELECT e.id, ct.id, 'Odometer (km)'
FROM equipment e
JOIN counter_types ct ON ct.name='odometer_km'
WHERE e.name='Tractor A';

-- Combine X: engine_hours only
INSERT INTO equipment_meters (equipment_id, meter_kind_id, label)
SELECT e.id, ct.id, 'Engine Hours'
FROM equipment e
JOIN counter_types ct ON ct.name='engine_hours'
WHERE e.name='Combine X';

-- Initial Readings
-- Tractor A
INSERT INTO meter_readings (meter_id, reading_value, reading_at, source)
SELECT emt.id, 100.0, NOW() - INTERVAL '90 days', 'seed'
FROM equipment_meters emt
JOIN equipment e ON e.id = emt.equipment_id
JOIN counter_types ct ON ct.id = emt.meter_kind_id
WHERE e.name='Tractor A' AND ct.name='engine_hours';

INSERT INTO meter_readings (meter_id, reading_value, reading_at, source)
SELECT emt.id, 3500.0, NOW() - INTERVAL '90 days', 'seed'
FROM equipment_meters emt
JOIN equipment e ON e.id = emt.equipment_id
JOIN counter_types ct ON ct.id = emt.meter_kind_id
WHERE e.name='Tractor A' AND ct.name='odometer_km';

-- Combine X
INSERT INTO meter_readings (meter_id, reading_value, reading_at, source)
SELECT emt.id, 50.0, NOW() - INTERVAL '60 days', 'seed'
FROM equipment_meters emt
JOIN equipment e ON e.id = emt.equipment_id
JOIN counter_types ct ON ct.id = emt.meter_kind_id
WHERE e.name='Combine X' AND ct.name='engine_hours';
