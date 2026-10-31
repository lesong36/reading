-- Proposed local schema, not yet wired into the application.
-- Requires SQLite >= 3.37. Run only on a new database through the migration runner.
-- Enable these connection settings on EVERY subsequent connection as well.
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = FULL;
PRAGMA busy_timeout = 5000;

BEGIN IMMEDIATE;

CREATE TABLE schema_migrations (
  version INTEGER PRIMARY KEY,
  applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
) STRICT;

-- Files live outside SQLite at assets/<first-two-hash-chars>/<sha256>.<png|jpg>.
-- Compute the hash from actual bytes; never take paths or hashes from the model.
CREATE TABLE assets (
  sha256 TEXT PRIMARY KEY NOT NULL
    CHECK (length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
  media_type TEXT NOT NULL CHECK (media_type IN ('image/png', 'image/jpeg')),
  pixel_width INTEGER NOT NULL CHECK (pixel_width > 0),
  pixel_height INTEGER NOT NULL CHECK (pixel_height > 0),
  byte_count INTEGER NOT NULL CHECK (byte_count > 0),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
) STRICT;
CREATE TRIGGER asset_metadata_immutable BEFORE UPDATE ON assets
BEGIN SELECT RAISE(ABORT, 'image asset metadata is immutable'); END;

CREATE TABLE questions (
  id TEXT PRIMARY KEY NOT NULL,
  title TEXT,
  subject TEXT NOT NULL DEFAULT 'math' CHECK (subject = 'math'),
  grade TEXT,
  source_question_number TEXT,
  question_type TEXT NOT NULL DEFAULT 'unknown'
    CHECK (question_type IN ('single_choice', 'multiple_choice', 'fill_blank', 'short_answer', 'mixed', 'unknown')),
  -- Canonical MAIN stem, including inline/display LaTeX and figure placeholders.
  -- Each option and subquestion is stored separately below, not duplicated here.
  stem_markup TEXT NOT NULL DEFAULT '',
  knowledge_tags_json TEXT NOT NULL DEFAULT '[]'
    CHECK (json_valid(knowledge_tags_json) AND json_type(knowledge_tags_json) = 'array'),
  reference_answer_markup TEXT,
  reference_answer_origin TEXT CHECK (reference_answer_origin IN ('source', 'user_verified')),
  mistake_note TEXT,
  review_state TEXT NOT NULL DEFAULT 'draft' CHECK (review_state IN ('draft', 'confirmed')),
  reviewed_at TEXT,
  revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  deleted_at TEXT,
  CHECK ((reference_answer_markup IS NULL) = (reference_answer_origin IS NULL)),
  CHECK (review_state = 'draft' OR (length(trim(stem_markup)) > 0 AND reviewed_at IS NOT NULL))
) STRICT;

-- One question may span several captures. One capture can supply several questions.
-- Rectangles use original-image pixels, TOP-LEFT origin, exclusive right/bottom edges.
CREATE TABLE question_sources (
  id TEXT PRIMARY KEY NOT NULL,
  question_id TEXT NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
  asset_sha256 TEXT NOT NULL REFERENCES assets(sha256) ON DELETE RESTRICT,
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  source_label TEXT,
  region_x INTEGER NOT NULL CHECK (region_x >= 0),
  region_y INTEGER NOT NULL CHECK (region_y >= 0),
  region_width INTEGER NOT NULL CHECK (region_width > 0),
  region_height INTEGER NOT NULL CHECK (region_height > 0),
  UNIQUE (question_id, ordinal),
  UNIQUE (question_id, id)
) STRICT;
CREATE INDEX question_sources_asset ON question_sources(asset_sha256);

CREATE TABLE question_parts (
  id TEXT PRIMARY KEY NOT NULL,
  question_id TEXT NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
  parent_part_id TEXT,
  label TEXT NOT NULL,
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  body_markup TEXT NOT NULL,
  reference_answer_markup TEXT,
  reference_answer_origin TEXT CHECK (reference_answer_origin IN ('source', 'user_verified')),
  UNIQUE (question_id, id),
  FOREIGN KEY (question_id, parent_part_id)
    REFERENCES question_parts(question_id, id) ON DELETE CASCADE,
  CHECK (parent_part_id IS NULL OR parent_part_id <> id),
  CHECK ((reference_answer_markup IS NULL) = (reference_answer_origin IS NULL))
) STRICT;
CREATE UNIQUE INDEX question_parts_order ON question_parts(question_id, coalesce(parent_part_id, ''), ordinal);

CREATE TABLE question_options (
  id TEXT PRIMARY KEY NOT NULL,
  question_id TEXT NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
  part_id TEXT,
  label TEXT NOT NULL,
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  body_markup TEXT NOT NULL DEFAULT '',
  UNIQUE (question_id, id),
  FOREIGN KEY (question_id, part_id)
    REFERENCES question_parts(question_id, id) ON DELETE CASCADE
) STRICT;
CREATE UNIQUE INDEX question_options_order ON question_options(question_id, coalesce(part_id, ''), ordinal);
CREATE UNIQUE INDEX question_options_label ON question_options(question_id, coalesce(part_id, ''), label);

CREATE TABLE question_figures (
  id TEXT PRIMARY KEY NOT NULL,
  question_id TEXT NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
  source_id TEXT NOT NULL,
  part_id TEXT,
  option_id TEXT,
  crop_asset_sha256 TEXT NOT NULL REFERENCES assets(sha256) ON DELETE RESTRICT,
  caption_markup TEXT,
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  region_x INTEGER NOT NULL CHECK (region_x >= 0),
  region_y INTEGER NOT NULL CHECK (region_y >= 0),
  region_width INTEGER NOT NULL CHECK (region_width > 0),
  region_height INTEGER NOT NULL CHECK (region_height > 0),
  FOREIGN KEY (question_id, source_id)
    REFERENCES question_sources(question_id, id) ON DELETE CASCADE,
  FOREIGN KEY (question_id, part_id)
    REFERENCES question_parts(question_id, id) ON DELETE CASCADE,
  FOREIGN KEY (question_id, option_id)
    REFERENCES question_options(question_id, id) ON DELETE CASCADE,
  CHECK (part_id IS NULL OR option_id IS NULL)
) STRICT;
CREATE UNIQUE INDEX question_figures_order ON question_figures(question_id, coalesce(part_id, ''), coalesce(option_id, ''), ordinal);
CREATE INDEX question_figures_source ON question_figures(source_id);
CREATE INDEX question_figures_asset ON question_figures(crop_asset_sha256);

-- Diagnostic extraction data is not the canonical question after user corrections.
-- raw_response_json contains the parsed response for THIS question, never API keys.
CREATE TABLE question_extractions (
  id TEXT PRIMARY KEY NOT NULL,
  question_id TEXT NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
  model TEXT NOT NULL,
  provider_host TEXT NOT NULL,
  prompt_version TEXT NOT NULL,
  response_schema_version INTEGER NOT NULL CHECK (response_schema_version >= 1),
  status TEXT NOT NULL CHECK (status IN ('succeeded', 'needs_review', 'failed')),
  raw_response_json TEXT CHECK (raw_response_json IS NULL OR json_valid(raw_response_json)),
  issues_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(issues_json) AND json_type(issues_json) = 'array'),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
) STRICT;
CREATE INDEX question_extractions_question ON question_extractions(question_id, created_at);

-- Future review attempts use separate rows; they do not overwrite the source answer.
CREATE TABLE question_attempts (
  id TEXT PRIMARY KEY NOT NULL,
  question_id TEXT NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
  part_id TEXT,
  student_answer_markup TEXT,
  student_work_asset_sha256 TEXT REFERENCES assets(sha256) ON DELETE RESTRICT,
  is_correct INTEGER CHECK (is_correct IN (0, 1)),
  feedback_markup TEXT,
  feedback_origin TEXT CHECK (feedback_origin IN ('user', 'ai')),
  attempted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  FOREIGN KEY (question_id, part_id)
    REFERENCES question_parts(question_id, id) ON DELETE CASCADE,
  CHECK (student_answer_markup IS NOT NULL OR student_work_asset_sha256 IS NOT NULL),
  CHECK ((feedback_markup IS NULL) = (feedback_origin IS NULL))
) STRICT;
CREATE INDEX question_attempts_question ON question_attempts(question_id, attempted_at);
CREATE INDEX question_attempts_asset ON question_attempts(student_work_asset_sha256);
CREATE INDEX questions_list ON questions(review_state, deleted_at, created_at);
CREATE INDEX questions_grade_type ON questions(grade, question_type);

CREATE TRIGGER source_bounds_insert BEFORE INSERT ON question_sources
WHEN NEW.region_x + NEW.region_width > (SELECT pixel_width FROM assets WHERE sha256 = NEW.asset_sha256)
  OR NEW.region_y + NEW.region_height > (SELECT pixel_height FROM assets WHERE sha256 = NEW.asset_sha256)
BEGIN SELECT RAISE(ABORT, 'source region outside original image'); END;
CREATE TRIGGER source_bounds_update BEFORE UPDATE ON question_sources
WHEN NEW.region_x + NEW.region_width > (SELECT pixel_width FROM assets WHERE sha256 = NEW.asset_sha256)
  OR NEW.region_y + NEW.region_height > (SELECT pixel_height FROM assets WHERE sha256 = NEW.asset_sha256)
BEGIN SELECT RAISE(ABORT, 'source region outside original image'); END;

CREATE TRIGGER figure_bounds_insert BEFORE INSERT ON question_figures
WHEN NEW.region_width <> (SELECT pixel_width FROM assets WHERE sha256 = NEW.crop_asset_sha256)
  OR NEW.region_height <> (SELECT pixel_height FROM assets WHERE sha256 = NEW.crop_asset_sha256)
  OR EXISTS (
  SELECT 1 FROM question_sources AS s WHERE s.id = NEW.source_id AND (
    NEW.region_x < s.region_x OR NEW.region_y < s.region_y
    OR NEW.region_x + NEW.region_width > s.region_x + s.region_width
    OR NEW.region_y + NEW.region_height > s.region_y + s.region_height
  )
)
BEGIN SELECT RAISE(ABORT, 'figure outside question source region'); END;
CREATE TRIGGER figure_bounds_update BEFORE UPDATE ON question_figures
WHEN NEW.region_width <> (SELECT pixel_width FROM assets WHERE sha256 = NEW.crop_asset_sha256)
  OR NEW.region_height <> (SELECT pixel_height FROM assets WHERE sha256 = NEW.crop_asset_sha256)
  OR EXISTS (
  SELECT 1 FROM question_sources AS s WHERE s.id = NEW.source_id AND (
    NEW.region_x < s.region_x OR NEW.region_y < s.region_y
    OR NEW.region_x + NEW.region_width > s.region_x + s.region_width
    OR NEW.region_y + NEW.region_height > s.region_y + s.region_height
  )
)
BEGIN SELECT RAISE(ABORT, 'figure outside question source region'); END;
CREATE TRIGGER source_retains_figures BEFORE UPDATE ON question_sources
WHEN NEW.asset_sha256 <> OLD.asset_sha256 OR EXISTS (
  SELECT 1 FROM question_figures AS f WHERE f.source_id = OLD.id AND (
    f.region_x < NEW.region_x OR f.region_y < NEW.region_y
    OR f.region_x + f.region_width > NEW.region_x + NEW.region_width
    OR f.region_y + f.region_height > NEW.region_y + NEW.region_height
  )
)
BEGIN SELECT RAISE(ABORT, 'source is immutable or would invalidate a figure'); END;

-- Prevent ordinary SQL clients from marking a screenshot question as confirmed
-- without at least one retained source. Further visual/formula validation is in-app.
CREATE TRIGGER confirmation_requires_source BEFORE UPDATE OF review_state ON questions
WHEN NEW.review_state = 'confirmed' AND NOT EXISTS (
  SELECT 1 FROM question_sources WHERE question_id = NEW.id
)
BEGIN SELECT RAISE(ABORT, 'confirmed question requires an original source'); END;
CREATE TRIGGER confirmation_not_direct_insert BEFORE INSERT ON questions
WHEN NEW.review_state = 'confirmed'
BEGIN SELECT RAISE(ABORT, 'insert draft with sources, then confirm'); END;
CREATE TRIGGER confirmed_source_retained BEFORE DELETE ON question_sources
WHEN EXISTS (SELECT 1 FROM questions WHERE id = OLD.question_id AND review_state = 'confirmed')
  AND (SELECT count(*) FROM question_sources WHERE question_id = OLD.question_id) = 1
BEGIN SELECT RAISE(ABORT, 'cannot remove the last source of a confirmed question'); END;

INSERT INTO schema_migrations(version) VALUES (1);
PRAGMA user_version = 1;
COMMIT;
