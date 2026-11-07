-- Drop existing tables to start fresh
DROP TABLE IF EXISTS raw_input CASCADE;
DROP TABLE IF EXISTS model_tree;
DROP TABLE IF EXISTS metadata_features CASCADE;

-- Step 1: Create a staging table to simulate loading raw text data
CREATE TABLE raw_input (
    "feature numeric 1" TEXT,
    "feature numeric 2" TEXT,
    "feature categorical 1" TEXT,
    "feature categorical 2" TEXT,
    "target class" TEXT
);

-- Step 2: Insert sample data as text
INSERT INTO raw_input ("feature numeric 1", "feature numeric 2", "feature categorical 1", "feature categorical 2", "target class") VALUES
('1.9', '90', 'yes', 'high', 'A'),
('2.5', '88', 'yes', 'high', 'A'),
('1.7', '85', 'yes', 'medium', 'A'),
('2.6', '30', 'no', 'low', 'B'),
('2.9', '40', 'no', 'medium', 'B'),
('1.9', '35', 'no', 'low', 'B'),
('1.6', '70', 'yes', 'low', 'A'),
('2.4', '65', 'yes', 'medium', 'B'),
('1.9', '50', 'no', 'high', 'A'),
('2.3', '55', 'yes', 'low', 'B'),
(NULL, '60', 'yes', 'medium', 'A'),
('2.0', NULL, 'no', 'low', 'B'),
('1.8', '75', NULL, 'high', 'A'),
('2.1', '45', 'yes', NULL, 'B');

-- Step 3: Create metadata table for features except target_class
CREATE TABLE metadata_features AS
SELECT
    column_name AS "feature name",
    CASE
        WHEN column_name IN ('"feature numeric 1"', '"feature numeric 2"') THEN 'numeric'
        ELSE 'categorical'
    END AS "feature type"
FROM information_schema.columns
WHERE table_name = 'raw_input'
  AND column_name <> '"target class"';

-- Step 4: Display column names and data types for raw_input
SELECT
    a.attname AS "Column",
    pg_catalog.format_type(a.atttypid, a.atttypmod) AS "Datatype"
FROM
    pg_catalog.pg_attribute a
WHERE
    a.attnum > 0
    AND NOT a.attisdropped
    AND a.attrelid = (
        SELECT c.oid
        FROM pg_catalog.pg_class c
            LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = 'raw_input'
            AND pg_catalog.pg_table_is_visible(c.oid)
    );

-- Step 5: Create table to store the decision tree structure
CREATE TABLE model_tree (
    node_id BIGINT,
    parent_id BIGINT,
    depth INT,
    split_feature TEXT,
    split_operator TEXT,
    split_value_numeric NUMERIC,
    split_value_text TEXT,
    predicted_class TEXT,
    condition_expression TEXT,
    split_condition TEXT
);

-- Step 6: Build decision tree using pre-processed data from raw_input
WITH RECURSIVE valid_data AS (
    SELECT
        CAST(NULLIF("feature numeric 1", '') AS NUMERIC) AS "feature numeric 1",
        CAST(NULLIF("feature numeric 2", '') AS NUMERIC) AS "feature numeric 2",
        "feature categorical 1",
        "feature categorical 2",
        "target class"
    FROM raw_input
    WHERE "feature numeric 1" IS NOT NULL
      AND "feature numeric 2" IS NOT NULL
      AND "feature categorical 1" IS NOT NULL
      AND "feature categorical 2" IS NOT NULL
      AND "target class" IS NOT NULL
),
feature_types AS (
    SELECT 
        "feature name",
        "feature type",
        CASE 
            WHEN "feature name" LIKE '%numeric%' THEN 'numeric'
            WHEN "feature name" LIKE '%categorical%' THEN 'categorical'
        END as feature_category
    FROM metadata_features
),
tree_structure AS (
    -- Anchor member: Root node
    SELECT
        1::BIGINT AS node_id,
        NULL::BIGINT AS parent_id,
        0 AS depth,
        NULL::TEXT AS split_feature,
        NULL::TEXT AS split_operator,
        NULL::NUMERIC AS split_value_numeric,
        NULL::TEXT AS split_value_text,
        (SELECT "target class" 
         FROM (SELECT "target class", COUNT(*) AS cnt 
               FROM valid_data
               GROUP BY "target class" 
               ORDER BY cnt DESC 
               LIMIT 1) majority) AS predicted_class,
        '' AS condition_expression,
        ARRAY[]::TEXT[] AS condition_list,
        NULL::TEXT AS split_condition
    UNION ALL
    -- Recursive member: Build child nodes
    SELECT
        parent.node_id * 10 + branch.branch,
        parent.node_id,
        parent.depth + 1,
        branch.feature,
        branch.operator,
        branch.value_numeric,
        branch.value_text,
        COALESCE((
            SELECT "target class" 
            FROM (
                SELECT "target class", COUNT(*) AS cnt
                FROM valid_data v
                JOIN feature_types ft ON ft."feature name" = parent.split_feature
                WHERE
                    -- Apply parent conditions using metadata type
                    (parent.split_feature IS NULL OR (
                        CASE ft.feature_category
                            WHEN 'numeric' THEN
                                CASE parent.split_feature
                                    WHEN '"feature numeric 1"' THEN
                                        (parent.split_operator = '<=' AND v."feature numeric 1" <= parent.split_value_numeric) OR
                                        (parent.split_operator = '>' AND v."feature numeric 1" > parent.split_value_numeric)
                                    WHEN '"feature numeric 2"' THEN
                                        (parent.split_operator = '<=' AND v."feature numeric 2" <= parent.split_value_numeric) OR
                                        (parent.split_operator = '>' AND v."feature numeric 2" > parent.split_value_numeric)
                                END
                            WHEN 'categorical' THEN
                                CASE parent.split_feature
                                    WHEN '"feature categorical 1"' THEN
                                        (parent.split_operator = '=' AND v."feature categorical 1" = parent.split_value_text) OR
                                        (parent.split_operator = '!=' AND v."feature categorical 1" <> parent.split_value_text)
                                    WHEN '"feature categorical 2"' THEN
                                        (parent.split_operator = '=' AND v."feature categorical 2" = parent.split_value_text) OR
                                        (parent.split_operator = '!=' AND v."feature categorical 2" <> parent.split_value_text)
                                END
                        END
                    ))
                    AND (
                        -- Apply current branch condition using metadata type
                        CASE ft.feature_category
                            WHEN 'numeric' THEN
                                CASE branch.feature
                                    WHEN '"feature numeric 1"' THEN
                                        (branch.operator = '<=' AND v."feature numeric 1" <= branch.value_numeric) OR
                                        (branch.operator = '>' AND v."feature numeric 1" > branch.value_numeric)
                                    WHEN '"feature numeric 2"' THEN
                                        (branch.operator = '<=' AND v."feature numeric 2" <= branch.value_numeric) OR
                                        (branch.operator = '>' AND v."feature numeric 2" > branch.value_numeric)
                                END
                            WHEN 'categorical' THEN
                                CASE branch.feature
                                    WHEN '"feature categorical 1"' THEN
                                        (branch.operator = '=' AND v."feature categorical 1" = branch.value_text) OR
                                        (branch.operator = '!=' AND v."feature categorical 1" <> branch.value_text)
                                    WHEN '"feature categorical 2"' THEN
                                        (branch.operator = '=' AND v."feature categorical 2" = branch.value_text) OR
                                        (branch.operator = '!=' AND v."feature categorical 2" <> branch.value_text)
                                END
                        END
                    )
                GROUP BY "target class"
                ORDER BY cnt DESC
                LIMIT 1
            ) majority
        ), NULL) AS predicted_class,
        CASE
            WHEN parent.condition_expression = '' THEN 
                branch.feature || ' ' || branch.operator || ' ' || COALESCE(branch.value_text, CAST(branch.value_numeric AS TEXT))
            ELSE 
                parent.condition_expression || ' AND ' || branch.feature || ' ' || branch.operator || ' ' || COALESCE(branch.value_text, CAST(branch.value_numeric AS TEXT))
        END AS condition_expression,
        parent.condition_list || branch.condition_key,
        branch.feature || ' ' || branch.operator || ' ' || COALESCE(branch.value_text, CAST(branch.value_numeric AS TEXT)) AS split_condition
    FROM tree_structure parent
    JOIN LATERAL (
        -- Compute optimal splits with pre-pruning
        WITH filtered_data AS (
            SELECT v.*, ft."feature type"
            FROM valid_data v
            JOIN feature_types ft ON ft."feature name" = parent.split_feature
            WHERE parent.split_feature IS NULL OR (
                CASE ft."feature type"
                    WHEN 'numeric' THEN
                        (parent.split_operator = '<=' AND v."feature numeric 1" <= parent.split_value_numeric) OR
                        (parent.split_operator = '>' AND v."feature numeric 1" > parent.split_value_numeric)
                    WHEN 'categorical' THEN
                        (parent.split_operator = '=' AND v."feature categorical 1" = parent.split_value_text) OR
                        (parent.split_operator = '!=' AND v."feature categorical 1" <> parent.split_value_text)
                END
            )
        ),
        node_classes AS (
            SELECT COUNT(DISTINCT "target class") AS num_classes
            FROM filtered_data
        ),
        totals AS (
            SELECT
                SUM(CASE WHEN "target class" = 'A' THEN 1 ELSE 0 END)::NUMERIC AS total_A,
                (COUNT(*) - SUM(CASE WHEN "target class" = 'A' THEN 1 ELSE 0 END))::NUMERIC AS total_B
            FROM filtered_data
        ),
        all_splits AS (
            SELECT 
                '"feature numeric 1"' AS feature, 
                '<=' AS operator, 
                NULL::TEXT AS value_text, 
                "feature numeric 1" AS value_numeric,
                CONCAT('"feature numeric 1"|<=|', CAST("feature numeric 1" AS TEXT)) AS condition_key
            FROM valid_data
            WHERE "feature numeric 1" IS NOT NULL
            UNION
            SELECT 
                '"feature numeric 2"', 
                '<=', 
                NULL::TEXT, 
                "feature numeric 2" AS value_numeric,
                CONCAT('"feature numeric 2"|<=|', CAST("feature numeric 2" AS TEXT))
            FROM valid_data
            WHERE "feature numeric 2" IS NOT NULL
            UNION
            SELECT 
                '"feature categorical 1"', 
                '=', 
                "feature categorical 1", 
                NULL::NUMERIC AS value_numeric,
                CONCAT('"feature categorical 1"|=|', "feature categorical 1")
            FROM valid_data
            WHERE "feature categorical 1" IS NOT NULL
            UNION
            SELECT 
                '"feature categorical 2"', 
                '=', 
                "feature categorical 2", 
                NULL::NUMERIC AS value_numeric,
                CONCAT('"feature categorical 2"|=|', "feature categorical 2")
            FROM valid_data
            WHERE "feature categorical 2" IS NOT NULL
        ),
        gini_calc AS (
            SELECT
                s.feature, 
                s.operator, 
                s.value_text, 
                s.value_numeric,
                s.condition_key,
                SUM(CASE WHEN
                    (s.feature = '"feature numeric 1"' AND f."feature numeric 1" <= s.value_numeric) OR
                    (s.feature = '"feature numeric 2"' AND f."feature numeric 2" <= s.value_numeric) OR
                    (s.feature = '"feature categorical 1"' AND f."feature categorical 1" = s.value_text) OR
                    (s.feature = '"feature categorical 2"' AND f."feature categorical 2" = s.value_text)
                    THEN CASE WHEN f."target class" = 'A' THEN 1 ELSE 0 END ELSE 0 END)::NUMERIC AS left_A,
                SUM(CASE WHEN
                    (s.feature = '"feature numeric 1"' AND f."feature numeric 1" <= s.value_numeric) OR
                    (s.feature = '"feature numeric 2"' AND f."feature numeric 2" <= s.value_numeric) OR
                    (s.feature = '"feature categorical 1"' AND f."feature categorical 1" = s.value_text) OR
                    (s.feature = '"feature categorical 2"' AND f."feature categorical 2" = s.value_text)
                    THEN CASE WHEN f."target class" = 'B' THEN 1 ELSE 0 END ELSE 0 END)::NUMERIC AS left_B,
                t.total_A,
                t.total_B
            FROM all_splits s
            CROSS JOIN filtered_data f
            CROSS JOIN totals t
            GROUP BY s.feature, s.operator, s.value_text, s.value_numeric, s.condition_key, t.total_A, t.total_B
        ),
        best_split AS (
            SELECT
                feature, 
                operator, 
                value_text, 
                value_numeric, 
                condition_key,
                (
                    (CAST(left_A + left_B AS NUMERIC) / NULLIF(total_A + total_B, 0)) *
                    (1.0 - POWER(CAST(left_A AS NUMERIC) / NULLIF(left_A + left_B, 0), 2) - 
                           POWER(CAST(left_B AS NUMERIC) / NULLIF(left_A + left_B, 0), 2))
                    +
                    (CAST((total_A - left_A) + (total_B - left_B) AS NUMERIC) / NULLIF(total_A + total_B, 0)) *
                    (1.0 - POWER(CAST(total_A - left_A AS NUMERIC) / NULLIF((total_A - left_A) + (total_B - left_B), 0), 2) - 
                           POWER(CAST(total_B - left_B AS NUMERIC) / NULLIF((total_A - left_A) + (total_B - left_B), 0), 2))
                ) AS gini_split
            FROM gini_calc
            WHERE
                NOT condition_key = ANY(parent.condition_list)
                AND (left_A + left_B >= 2)
                AND ((total_A - left_A) + (total_B - left_B) >= 2)
            ORDER BY gini_split ASC
            LIMIT 1
        ),
        make_branches AS (
            SELECT 
                feature, 
                operator, 
                value_text, 
                value_numeric, 
                condition_key, 
                1 AS branch
            FROM best_split
            WHERE EXISTS (
                SELECT 1 FROM filtered_data f WHERE
                    CASE
                        WHEN feature = '"feature numeric 1"' THEN f."feature numeric 1" <= value_numeric
                        WHEN feature = '"feature numeric 2"' THEN f."feature numeric 2" <= value_numeric
                        WHEN feature = '"feature categorical 1"' THEN f."feature categorical 1" = value_text
                        WHEN feature = '"feature categorical 2"' THEN f."feature categorical 2" = value_text
                    END
            )
            UNION ALL
            SELECT 
                feature,
                CASE WHEN feature IN ('"feature numeric 1"', '"feature numeric 2"') THEN '>' ELSE '!=' END,
                value_text,
                value_numeric,
                CONCAT(feature, '|', 
                       CASE WHEN feature IN ('"feature numeric 1"', '"feature numeric 2"') THEN '>' ELSE '!=' END, 
                       '|', COALESCE(value_text, CAST(value_numeric AS TEXT))) AS condition_key,
                2 AS branch
            FROM best_split
            WHERE EXISTS (
                SELECT 1 FROM filtered_data f WHERE
                    NOT (
                        CASE
                            WHEN feature = '"feature numeric 1"' THEN f."feature numeric 1" <= value_numeric
                            WHEN feature = '"feature numeric 2"' THEN f."feature numeric 2" <= value_numeric
                            WHEN feature = '"feature categorical 1"' THEN f."feature categorical 1" = value_text
                            WHEN feature = '"feature categorical 2"' THEN f."feature categorical 2" = value_text
                        END
                    )
            )
        )
        SELECT * FROM make_branches
        WHERE (SELECT num_classes FROM node_classes) > 1
    ) branch ON parent.depth < 10
)
-- Insert the tree structure into the model_tree table
INSERT INTO model_tree
SELECT 
    node_id, 
    parent_id, 
    depth, 
    split_feature, 
    split_operator, 
    split_value_numeric, 
    split_value_text, 
    predicted_class, 
    condition_expression, 
    split_condition
FROM tree_structure;

-- Set predicted_class to NULL for internal nodes
UPDATE model_tree
SET predicted_class = NULL
WHERE node_id IN (SELECT parent_id FROM model_tree WHERE parent_id IS NOT NULL);

-- Display the final decision tree
SELECT DISTINCT ON (node_id)
    node_id, 
    parent_id, 
    depth, 
    split_feature, 
    split_operator, 
    split_value_numeric, 
    split_value_text, 
    predicted_class, 
    condition_expression, 
    split_condition
FROM model_tree
ORDER BY node_id;