-- upscaler-bridge schema
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
    device_model VARCHAR(50),

    INDEX idx_device_history (device_id, created_at),
    INDEX idx_technique (technique, created_at),
    INDEX idx_failures (success, created_at)
);
