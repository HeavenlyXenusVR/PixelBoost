-- upscaler-bridge schema (PostgreSQL)
--
-- One append-only row per upscale attempt (success or failure) — this is a
-- debugging/analytics log, not a sync mechanism, so nothing here is ever
-- updated in place after insert.

CREATE TABLE IF NOT EXISTS upscale_history (
    id VARCHAR(36) PRIMARY KEY,
    -- Anonymous per-install identifier (UUID persisted in UserDefaults) —
    -- this app has no user accounts, so there's no real user_id to key on.
    device_id VARCHAR(64) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    -- Source image.
    source_width INT NOT NULL,
    source_height INT NOT NULL,
    source_file_size_bytes INT,

    -- Technique actually used for this run — 'coreml_tile' or
    -- 'lanczos_fallback' (see UpscaleResult.technique on the iOS side).
    -- model_name/tile_size/overlap are NULL for the Lanczos fallback, which
    -- has no model or tiling.
    technique VARCHAR(30) NOT NULL,
    model_name VARCHAR(100),
    tile_size INT,
    overlap INT,
    scale_factor INT NOT NULL,
    tile_count INT,

    -- Result.
    output_width INT,
    output_height INT,
    processing_ms INT NOT NULL,
    success BOOLEAN NOT NULL,
    error_message TEXT,

    -- Device context — helps tell "this model is slow on all devices" apart
    -- from "this one device/OS version is the problem".
    app_version VARCHAR(20),
    os_version VARCHAR(20),
    device_model VARCHAR(50)
);
CREATE INDEX IF NOT EXISTS idx_device_history ON upscale_history (device_id, created_at);
CREATE INDEX IF NOT EXISTS idx_technique ON upscale_history (technique, created_at);
CREATE INDEX IF NOT EXISTS idx_failures ON upscale_history (success, created_at);

-- General-purpose action log — anything that isn't a full upscale attempt
-- (Save, Compare Models, Cutout, a Settings change, ...) but is still worth
-- having a record of when debugging a report we can't reproduce locally.
-- `detail` is a free-form JSON blob per action rather than a wide sparse
-- column set, since what's worth recording varies a lot by action.
CREATE TABLE IF NOT EXISTS action_log (
    id VARCHAR(36) PRIMARY KEY,
    device_id VARCHAR(64) NOT NULL,
    action VARCHAR(50) NOT NULL,
    detail TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    app_version VARCHAR(20),
    os_version VARCHAR(20),
    device_model VARCHAR(50)
);
CREATE INDEX IF NOT EXISTS idx_device_action ON action_log (device_id, action, created_at);

-- ---------------------------------------------------------------------------
-- Temporary image storage (imports/exports) — expiring, not permanent
-- ---------------------------------------------------------------------------

-- A device's original (pre-upscale) photos, uploaded on request — NOT part
-- of the normal on-device upscale flow (which never leaves the phone). This
-- exists purely as an opt-in backup/handoff mechanism: e.g. queue a photo
-- here before a batch job, or move a photo to another device without
-- AirDrop. Rows are deleted automatically once `expires_at` passes (see
-- main.py's cleanup loop) — this is temporary scratch storage, not a photo
-- library.
CREATE TABLE IF NOT EXISTS image_imports (
    id VARCHAR(36) PRIMARY KEY,
    device_id VARCHAR(64) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP NOT NULL,
    filename VARCHAR(255),
    content_type VARCHAR(100) DEFAULT 'image/jpeg',
    width INT,
    height INT,
    file_size_bytes INT NOT NULL,
    image_data BYTEA NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_device_imports ON image_imports (device_id, created_at);
CREATE INDEX IF NOT EXISTS idx_import_expiry ON image_imports (expires_at);

-- A device's upscaled results, uploaded on request — lets a result be
-- re-fetched (e.g. after local storage was cleared, or from a second
-- device) without re-running the model. Optionally linked back to the
-- upscale_history row that produced it. Same auto-expiry as image_imports.
CREATE TABLE IF NOT EXISTS image_exports (
    id VARCHAR(36) PRIMARY KEY,
    device_id VARCHAR(64) NOT NULL,
    history_id VARCHAR(36) REFERENCES upscale_history(id) ON DELETE SET NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP NOT NULL,
    filename VARCHAR(255),
    content_type VARCHAR(100) DEFAULT 'image/png',
    width INT,
    height INT,
    file_size_bytes INT NOT NULL,
    image_data BYTEA NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_device_exports ON image_exports (device_id, created_at);
CREATE INDEX IF NOT EXISTS idx_export_expiry ON image_exports (expires_at);

-- ---------------------------------------------------------------------------
-- Customization
-- ---------------------------------------------------------------------------

-- User-named model+overlap combinations beyond the built-in Fast/Standard/
-- Best presets — e.g. "Portrait" = anime model + overlap 12. Permanent
-- (not expiring) — these are deliberate user configuration, not scratch data.
CREATE TABLE IF NOT EXISTS custom_presets (
    id VARCHAR(36) PRIMARY KEY,
    device_id VARCHAR(64) NOT NULL,
    name VARCHAR(100) NOT NULL,
    model_name VARCHAR(100) NOT NULL,
    overlap INT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (device_id, name)
);
CREATE INDEX IF NOT EXISTS idx_device_presets ON custom_presets (device_id);

-- Per-device settings backup. This app has no accounts, so "sync" here
-- really means "manually-triggered backup/restore to/from one server
-- record keyed by device_id" (see Settings' Backup/Restore actions),
-- not automatic multi-device sync. `updated_at` is set explicitly by the
-- app's own upsert query (see main.py's upsert_device_settings) — MySQL's
-- `ON UPDATE CURRENT_TIMESTAMP` column attribute this table used to declare
-- has no Postgres equivalent short of a trigger, and an explicit
-- `updated_at = CURRENT_TIMESTAMP` in the one query that ever touches this
-- row is simpler than adding one.
CREATE TABLE IF NOT EXISTS device_settings (
    device_id VARCHAR(64) PRIMARY KEY,
    haptics_enabled BOOLEAN DEFAULT TRUE,
    model_choice VARCHAR(50) DEFAULT 'generalPhoto',
    quality VARCHAR(50) DEFAULT 'standard',
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Metadata about bundled models — richer, server-editable descriptions
-- than hardcoding strings in the Swift client, and a natural place to add
-- new model entries' documentation ahead of an app update that bundles
-- them. `is_active` lets a model be listed without yet being recommended.
CREATE TABLE IF NOT EXISTS model_registry (
    model_name VARCHAR(100) PRIMARY KEY,
    display_name VARCHAR(100) NOT NULL,
    description TEXT,
    license VARCHAR(100),
    tile_size INT NOT NULL,
    scale_factor INT NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO model_registry (model_name, display_name, description, license, tile_size, scale_factor, is_active) VALUES
    ('RealESRGAN', 'General Photo', 'Real-ESRGAN x4plus — general-purpose photo upscaling, 23 RRDB blocks.', 'BSD-3-Clause', 128, 4, TRUE),
    ('RealESRGANAnime', 'Anime / Illustration', 'Real-ESRGAN x4plus anime_6B — optimized for anime/illustration art, 6 RRDB blocks (faster).', 'BSD-3-Clause', 128, 4, TRUE)
ON CONFLICT (model_name) DO UPDATE SET display_name = EXCLUDED.display_name;
