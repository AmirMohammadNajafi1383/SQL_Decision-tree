-- Drop existing tables to start fresh
DROP TABLE IF EXISTS raw_input CASCADE;
DROP TABLE IF EXISTS features_input CASCADE;
DROP TABLE IF EXISTS model_tree;
DROP TABLE IF EXISTS metadata_features CASCADE;

-- Step 1: Create a staging table to simulate loading raw text data (e.g., from a text file)
CREATE TABLE raw_input (
    "feature numeric 1" TEXT, -- Initially text, will be cast to NUMERIC
    "feature numeric 2" TEXT, -- Initially text, will be cast to NUMERIC
    "feature categorical 1" TEXT,
    "feature categorical 2" TEXT,
    "target class" TEXT
);

-- Step 2: Insert sample data as text (simulating text file input)
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

-- Step 3: Create metadata table for features with dynamic type detection
CREATE TABLE metadata_features AS
WITH feature_stats AS (
    SELECT 
        column_name,
        CASE 
            WHEN column_name = '"target class"' THEN 'target'
            WHEN column_name LIKE '%numeric%' THEN 'numeric'
            ELSE 'categorical'
        END as expected_type,
        CASE 
            WHEN column_name = '"target class"' THEN 'target'
            WHEN column_name LIKE '%numeric%' THEN 
                CASE 
                    WHEN COUNT(*) = COUNT(
                        CASE 
                            WHEN column_value ~ '^[+-]?([0-9]*[.])?[0-9]+$' 
                            AND column_value IS NOT NULL 
                            THEN 1 
                        END
                    ) THEN 'numeric'
                    ELSE 'categorical'
                END
            ELSE 'categorical'
        END as detected_type,
        COUNT(DISTINCT column_value) as unique_values,
        COUNT(*) as total_values,
        COUNT(CASE WHEN column_value IS NULL OR column_value = '' THEN 1 END) as null_count,
        MIN(CASE 
            WHEN column_value ~ '^[+-]?([0-9]*[.])?[0-9]+$' 
            THEN CAST(column_value AS NUMERIC) 
        END) as min_numeric_value,
        MAX(CASE 
            WHEN column_value ~ '^[+-]?([0-9]*[.])?[0-9]+$' 
            THEN CAST(column_value AS NUMERIC) 
        END) as max_numeric_value
    FROM raw_input
    CROSS JOIN LATERAL (
        VALUES 
            ('"feature numeric 1"', "feature numeric 1"),
            ('"feature numeric 2"', "feature numeric 2"),
            ('"feature categorical 1"', "feature categorical 1"),
            ('"feature categorical 2"', "feature categorical 2"),
            ('"target class"', "target class")
    ) AS t(column_name, column_value)
    GROUP BY column_name
)
SELECT 
    column_name as "feature name",
    detected_type as "feature type",
    expected_type as "expected type",
    unique_values,
    total_values,
    null_count,
    min_numeric_value,
    max_numeric_value,
    CASE 
        WHEN detected_type = 'numeric' THEN 'numeric'
        WHEN detected_type = 'categorical' AND unique_values <= 10 THEN 'categorical_small'
        ELSE 'categorical_large'
    END as "processing type",
    CASE 
        WHEN detected_type = 'numeric' AND (max_numeric_value - min_numeric_value) > 0 
        THEN (max_numeric_value - min_numeric_value) / 10  -- برای تقسیم‌بندی بهتر
        ELSE NULL 
    END as "numeric_step"
FROM feature_stats
WHERE column_name != '"target class"';

-- Step 4: Create the main input table with proper data types based on metadata
CREATE TABLE features_input AS
WITH safe_cast AS (
    SELECT 
        "feature name",
        "feature type",
        CASE 
            WHEN "feature type" = 'numeric' THEN 
                CASE 
                    WHEN "feature numeric 1" ~ '^[+-]?([0-9]*[.])?[0-9]+$' 
                    THEN CAST("feature numeric 1" AS NUMERIC)
                    ELSE NULL::NUMERIC 
                END
            ELSE NULL::NUMERIC
        END as safe_numeric_1,
        CASE 
            WHEN "feature type" = 'numeric' THEN 
                CASE 
                    WHEN "feature numeric 2" ~ '^[+-]?([0-9]*[.])?[0-9]+$' 
                    THEN CAST("feature numeric 2" AS NUMERIC)
                    ELSE NULL::NUMERIC 
                END
            ELSE NULL::NUMERIC
        END as safe_numeric_2,
        CASE 
            WHEN "feature type" = 'categorical' THEN "feature numeric 1"
            ELSE NULL::TEXT
        END as safe_categorical_1,
        CASE 
            WHEN "feature type" = 'categorical' THEN "feature numeric 2"
            ELSE NULL::TEXT
        END as safe_categorical_2
    FROM raw_input r
    CROSS JOIN metadata_features m
    WHERE m."feature name" = '"feature numeric 1"'
)
SELECT 
    CASE 
        WHEN m."feature type" = 'numeric' THEN s.safe_numeric_1
        ELSE NULL::NUMERIC
    END as "feature numeric 1",
    CASE 
        WHEN m."feature type" = 'numeric' THEN s.safe_numeric_2
        ELSE NULL::NUMERIC
    END as "feature numeric 2",
    CASE 
        WHEN m."feature type" = 'categorical' THEN s.safe_categorical_1
        ELSE r."feature categorical 1"
    END as "feature categorical 1",
    CASE 
        WHEN m."feature type" = 'categorical' THEN s.safe_categorical_2
        ELSE r."feature categorical 2"
    END as "feature categorical 2",
    r."target class"
FROM raw_input r
CROSS JOIN safe_cast s
CROSS JOIN metadata_features m
WHERE m."feature name" = '"feature numeric 1"';

-- Step 5: Create table to store the decision tree structure
CREATE TABLE model_tree (
    node_id BIGINT,
    parent_id BIGINT,
    depth INT,
    split_feature TEXT,
    split_operator TEXT,
    split_value_numeric NUMERIC, -- Numeric splits stored as NUMERIC
    split_value_text TEXT, -- Text splits for categorical features (e.g., 'low', 'medium')
    predicted_class TEXT,
    condition_expression TEXT, -- Human-readable output
    split_condition TEXT -- Human-readable output
);

-- Step 6: Build decision tree using dynamic feature types
WITH RECURSIVE valid_data AS (
    SELECT *
    FROM features_input
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
        "processing type",
        "numeric_step"
    FROM metadata_features
),
numeric_splits AS (
    SELECT 
        f."feature name" as feature,
        '<='::TEXT as operator,
        NULL::TEXT as value_text,
        generate_series(
            CAST(m.min_numeric_value AS NUMERIC),
            CAST(m.max_numeric_value AS NUMERIC),
            COALESCE(m."numeric_step", (m.max_numeric_value - m.min_numeric_value) / 10)
        ) as value_numeric,
        CONCAT(f."feature name", '|<=|', 
               CAST(generate_series(
                   CAST(m.min_numeric_value AS NUMERIC),
                   CAST(m.max_numeric_value AS NUMERIC),
                   COALESCE(m."numeric_step", (m.max_numeric_value - m.min_numeric_value) / 10)
               ) AS TEXT)) as condition_key
    FROM feature_types f
    JOIN metadata_features m ON f."feature name" = m."feature name"
    WHERE f."feature type" = 'numeric'
),
categorical_splits AS (
    SELECT 
        f."feature name" as feature,
        '='::TEXT as operator,
        v.column_value as value_text,
        NULL::NUMERIC as value_numeric,
        CONCAT(f."feature name", '|=|', v.column_value) as condition_key
    FROM feature_types f
    CROSS JOIN LATERAL (
        SELECT DISTINCT column_value::TEXT
        FROM valid_data
        CROSS JOIN LATERAL (
            VALUES 
                ('"feature categorical 1"', "feature categorical 1"::TEXT),
                ('"feature categorical 2"', "feature categorical 2"::TEXT)
        ) AS t(column_name, column_value)
        WHERE column_name = f."feature name"
    ) v
    WHERE f."feature type" = 'categorical'
    AND v.column_value IS NOT NULL
),
all_splits AS (
    SELECT 
        feature,
        operator,
        value_text,
        value_numeric,
        condition_key,
        CASE 
            WHEN operator = '<=' THEN 
                CASE 
                    WHEN feature = '"feature numeric 1"' THEN 
                        "feature numeric 1" <= value_numeric
                    WHEN feature = '"feature numeric 2"' THEN 
                        "feature numeric 2" <= value_numeric
                    ELSE FALSE
                END
            ELSE 
                CASE 
                    WHEN feature = '"feature categorical 1"' THEN 
                        "feature categorical 1" = value_text
                    WHEN feature = '"feature categorical 2"' THEN 
                        "feature categorical 2" = value_text
                    ELSE FALSE
                END
        END as condition
    FROM (
        SELECT * FROM numeric_splits
        UNION ALL
        SELECT * FROM categorical_splits
    ) s
    CROSS JOIN valid_data
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
                FROM valid_data
                WHERE
                    -- Apply parent conditions with proper numeric casting
                    (parent.split_feature IS NULL OR (
                        CASE
                            WHEN parent.split_feature = '"feature numeric 1"' THEN
                                (parent.split_operator = '<=' AND CAST("feature numeric 1" AS NUMERIC) <= parent.split_value_numeric) OR
                                (parent.split_operator = '>' AND CAST("feature numeric 1" AS NUMERIC) > parent.split_value_numeric)
                            WHEN parent.split_feature = '"feature numeric 2"' THEN
                                (parent.split_operator = '<=' AND CAST("feature numeric 2" AS NUMERIC) <= parent.split_value_numeric) OR
                                (parent.split_operator = '>' AND CAST("feature numeric 2" AS NUMERIC) > parent.split_value_numeric)
                            WHEN parent.split_feature = '"feature categorical 1"' THEN
                                (parent.split_operator = '=' AND "feature categorical 1" = parent.split_value_text) OR
                                (parent.split_operator = '!=' AND "feature categorical 1" <> parent.split_value_text)
                            WHEN parent.split_feature = '"feature categorical 2"' THEN
                                (parent.split_operator = '=' AND "feature categorical 2" = parent.split_value_text) OR
                                (parent.split_operator = '!=' AND "feature categorical 2" <> parent.split_value_text)
                        END
                    ))
                    AND (
                        -- Apply current branch condition with proper numeric casting
                        CASE
                            WHEN branch.feature = '"feature numeric 1"' THEN
                                (branch.operator = '<=' AND CAST("feature numeric 1" AS NUMERIC) <= branch.value_numeric) OR
                                (branch.operator = '>' AND CAST("feature numeric 1" AS NUMERIC) > branch.value_numeric)
                            WHEN branch.feature = '"feature numeric 2"' THEN
                                (branch.operator = '<=' AND CAST("feature numeric 2" AS NUMERIC) <= branch.value_numeric) OR
                                (branch.operator = '>' AND CAST("feature numeric 2" AS NUMERIC) > branch.value_numeric)
                            WHEN branch.feature = '"feature categorical 1"' THEN
                                (branch.operator = '=' AND "feature categorical 1" = branch.value_text) OR
                                (branch.operator = '!=' AND "feature categorical 1" <> branch.value_text)
                            WHEN branch.feature = '"feature categorical 2"' THEN
                                (branch.operator = '=' AND "feature categorical 2" = branch.value_text) OR
                                (branch.operator = '!=' AND "feature categorical 2" <> branch.value_text)
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
            SELECT * FROM valid_data
            WHERE parent.split_feature IS NULL OR (
                CASE
                    WHEN parent.split_feature = '"feature numeric 1"' THEN
                        (parent.split_operator = '<=' AND CAST("feature numeric 1" AS NUMERIC) <= parent.split_value_numeric) OR
                        (parent.split_operator = '>' AND CAST("feature numeric 1" AS NUMERIC) > parent.split_value_numeric)
                    WHEN parent.split_feature = '"feature numeric 2"' THEN
                        (parent.split_operator = '<=' AND CAST("feature numeric 2" AS NUMERIC) <= parent.split_value_numeric) OR
                        (parent.split_operator = '>' AND CAST("feature numeric 2" AS NUMERIC) > parent.split_value_numeric)
                    WHEN parent.split_feature = '"feature categorical 1"' THEN
                        (parent.split_operator = '=' AND "feature categorical 1" = parent.split_value_text) OR
                        (parent.split_operator = '!=' AND "feature categorical 1" <> parent.split_value_text)
                    WHEN parent.split_feature = '"feature categorical 2"' THEN
                        (parent.split_operator = '=' AND "feature categorical 2" = parent.split_value_text) OR
                        (parent.split_operator = '!=' AND "feature categorical 2" <> parent.split_value_text)
                END
            )
        ),
        node_classes AS (
            SELECT COUNT(DISTINCT "target class") AS num_classes
            FROM filtered_data
        ),
        totals AS (
            SELECT
                COUNT(*)::NUMERIC as total_count,
                SUM(CASE WHEN "target class" = 'A' THEN 1 ELSE 0 END)::NUMERIC AS total_A,
                SUM(CASE WHEN "target class" = 'B' THEN 1 ELSE 0 END)::NUMERIC AS total_B
            FROM filtered_data
        ),
        gini_calc AS (
            SELECT
                s.feature,
                s.operator,
                s.value_text,
                s.value_numeric,
                s.condition_key,
                COUNT(*) OVER (PARTITION BY s.feature, s.operator, s.value_text, s.value_numeric) as total_count,
                SUM(CASE WHEN s.condition AND f."target class" = 'A' THEN 1 ELSE 0 END) OVER (PARTITION BY s.feature, s.operator, s.value_text, s.value_numeric) as left_A,
                SUM(CASE WHEN s.condition AND f."target class" = 'B' THEN 1 ELSE 0 END) OVER (PARTITION BY s.feature, s.operator, s.value_text, s.value_numeric) as left_B,
                t.total_count as grand_total,
                t.total_A as grand_total_A,
                t.total_B as grand_total_B
            FROM all_splits s
            CROSS JOIN filtered_data f
            CROSS JOIN totals t
        ),
        best_split AS (
            SELECT
                feature, 
                operator, 
                value_text, 
                value_numeric, 
                condition_key,
                (
                    (CAST(left_A + left_B AS NUMERIC) / NULLIF(grand_total, 0)) *
                    (1.0 - POWER(CAST(left_A AS NUMERIC) / NULLIF(left_A + left_B, 0), 2) - 
                           POWER(CAST(left_B AS NUMERIC) / NULLIF(left_A + left_B, 0), 2))
                    +
                    (CAST((grand_total_A - left_A) + (grand_total_B - left_B) AS NUMERIC) / NULLIF(grand_total, 0)) *
                    (1.0 - POWER(CAST(grand_total_A - left_A AS NUMERIC) / NULLIF((grand_total_A - left_A) + (grand_total_B - left_B), 0), 2) - 
                           POWER(CAST(grand_total_B - left_B AS NUMERIC) / NULLIF((grand_total_A - left_A) + (grand_total_B - left_B), 0), 2))
                ) AS gini_split
            FROM gini_calc
            WHERE
                NOT condition_key = ANY(parent.condition_list)
                AND (left_A + left_B >= 2)
                AND ((grand_total_A - left_A) + (grand_total_B - left_B) >= 2)
                AND left_A + left_B < grand_total  -- Ensure we're not taking all data
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
                        WHEN feature = '"feature numeric 1"' AND value_numeric IS NOT NULL THEN 
                            CAST(f."feature numeric 1" AS NUMERIC) <= value_numeric
                        WHEN feature = '"feature numeric 2"' AND value_numeric IS NOT NULL THEN 
                            CAST(f."feature numeric 2" AS NUMERIC) <= value_numeric
                        WHEN feature = '"feature categorical 1"' AND value_text IS NOT NULL THEN 
                            f."feature categorical 1" = value_text
                        WHEN feature = '"feature categorical 2"' AND value_text IS NOT NULL THEN 
                            f."feature categorical 2" = value_text
                        ELSE FALSE
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
                            WHEN feature = '"feature numeric 1"' AND value_numeric IS NOT NULL THEN 
                                CAST(f."feature numeric 1" AS NUMERIC) <= value_numeric
                            WHEN feature = '"feature numeric 2"' AND value_numeric IS NOT NULL THEN 
                                CAST(f."feature numeric 2" AS NUMERIC) <= value_numeric
                            WHEN feature = '"feature categorical 1"' AND value_text IS NOT NULL THEN 
                                f."feature categorical 1" = value_text
                            WHEN feature = '"feature categorical 2"' AND value_text IS NOT NULL THEN 
                                f."feature categorical 2" = value_text
                            ELSE FALSE
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

-- Display diagnostic information
-- Check if data exists in tables
SELECT 'raw_input' as table_name, COUNT(*) as row_count FROM raw_input
UNION ALL
SELECT 'features_input', COUNT(*) FROM features_input
UNION ALL
SELECT 'metadata_features', COUNT(*) FROM metadata_features
UNION ALL
SELECT 'model_tree', COUNT(*) FROM model_tree;

-- Check metadata_features content
SELECT * FROM metadata_features;

-- Check features_input content
SELECT * FROM features_input LIMIT 5;

-- Display the final decision tree with better formatting
WITH tree_display AS (
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
        split_condition,
        CASE 
            WHEN parent_id IS NULL THEN 'Root'
            WHEN predicted_class IS NOT NULL THEN 'Leaf'
            ELSE 'Internal'
        END as node_type,
        REPEAT('    ', depth) || 
        CASE 
            WHEN parent_id IS NULL THEN 'Root'
            WHEN predicted_class IS NOT NULL THEN 'Leaf: ' || predicted_class
            ELSE split_feature || ' ' || split_operator || ' ' || 
                 COALESCE(CAST(split_value_numeric AS TEXT), split_value_text)
        END as tree_display
    FROM model_tree
)
SELECT 
    node_id,
    parent_id,
    depth,
    node_type,
    tree_display,
    split_feature,
    split_operator,
    split_value_numeric,
    split_value_text,
    predicted_class,
    condition_expression,
    split_condition
FROM tree_display
ORDER BY node_id;

-- اضافه کردن ایندکس برای بهبود عملکرد
CREATE INDEX idx_features_input_numeric1 ON features_input ("feature numeric 1");
CREATE INDEX idx_features_input_numeric2 ON features_input ("feature numeric 2");
CREATE INDEX idx_features_input_categorical1 ON features_input ("feature categorical 1");
CREATE INDEX idx_features_input_categorical2 ON features_input ("feature categorical 2");