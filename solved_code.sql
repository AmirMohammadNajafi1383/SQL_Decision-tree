-- Drop existing tables and materialized view to start fresh
DROP TABLE IF EXISTS raw_input CASCADE;
DROP TABLE IF EXISTS features_input CASCADE;
DROP TABLE IF EXISTS model_tree;
DROP MATERIALIZED VIEW IF EXISTS cleaned_data;

-- Step 1: Create a staging table to simulate loading raw text data (e.g., from a text file)
CREATE TABLE raw_input (
    feature_numeric_1 TEXT, -- Initially text, will be cast to NUMERIC
    feature_numeric_2 TEXT, -- Initially text, will be cast to NUMERIC
    feature_categorical_1 TEXT,
    feature_categorical_2 TEXT,
    target_class TEXT
);

-- Step 2: Insert sample data as text (simulating text file input)
INSERT INTO raw_input (feature_numeric_1, feature_numeric_2, feature_categorical_1, feature_categorical_2, target_class) VALUES
('1.5', '90.00', 'yes', 'high', 'A'),
('2.5', '88.00', 'yes', 'high', 'A'),
('1.7', '85.00', 'yes', 'medium', 'A'),
('2.6', '30.00', 'no', 'low', 'B'),
('2.9', '40.00', 'no', 'medium', 'B'),
('1.9', '35.00', 'no', 'low', 'B'),
('1.6', '70.00', 'yes', 'low', 'A'),
('2.4', '65.00', 'yes', 'medium', 'B'),
('1.9', '50.00', 'no', 'high', 'A'),
('2.3', '55.00', 'yes', 'low', 'B'),
(NULL, '60.00', 'yes', 'medium', 'A'),
('2.0', NULL, 'no', 'low', 'B'),
('1.8', '75.00', NULL, 'high', 'A'),
('2.1', '45.00', 'yes', NULL, 'B');

-- Step 3: Create the main input table with proper data types
CREATE TABLE features_input (
    feature_numeric_1 NUMERIC, -- Store as NUMERIC for efficiency
    feature_numeric_2 NUMERIC, -- Store as NUMERIC for efficiency
    feature_categorical_1 TEXT, -- Retain text for categorical data
    feature_categorical_2 TEXT, -- Retain text for categorical data
    target_class TEXT -- Retain text for target class
);

-- Step 4: Load data from raw_input to features_input, casting text to NUMERIC where needed
INSERT INTO features_input
SELECT 
    CAST(NULLIF(feature_numeric_1, '') AS NUMERIC),
    CAST(NULLIF(feature_numeric_2, '') AS NUMERIC),
    feature_categorical_1,
    feature_categorical_2,
    target_class
FROM raw_input;

-- Step 5: Create materialized view to store cleaned data, preserving both numeric and text columns
CREATE MATERIALIZED VIEW cleaned_data AS
SELECT
    feature_numeric_1, -- Stored as NUMERIC
    feature_numeric_2, -- Stored as NUMERIC
    feature_categorical_1, -- Stored as TEXT (e.g., 'yes', 'no')
    feature_categorical_2, -- Stored as TEXT (e.g., 'low', 'medium', 'high')
    target_class -- Stored as TEXT (e.g., 'A', 'B')
FROM features_input
WHERE feature_numeric_1 IS NOT NULL
  AND feature_numeric_2 IS NOT NULL
  AND feature_categorical_1 IS NOT NULL
  AND feature_categorical_2 IS NOT NULL
  AND target_class IS NOT NULL;

-- Step 6: Create index on materialized view for faster queries
CREATE INDEX idx_cleaned_data ON cleaned_data (feature_numeric_1, feature_numeric_2, feature_categorical_1, feature_categorical_2, target_class);

-- Step 6.1: Create a temporary table preserving numeric and text types
CREATE TEMP TABLE temp_cleaned_data AS
SELECT
    feature_numeric_1,        -- NUMERIC
    feature_numeric_2,        -- NUMERIC
    feature_categorical_1,    -- TEXT
    feature_categorical_2,    -- TEXT
    target_class              -- TEXT
FROM cleaned_data;

-- (Optional) Check the structure and contents of the temporary table
SELECT * FROM temp_cleaned_data;

-- Step 7: Verify the contents of the materialized view to ensure text data is visible
SELECT * FROM cleaned_data;

-- Step 8: Create table to store the decision tree structure
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

-- Step 9: Build decision tree using pre-processed data from the materialized view
WITH RECURSIVE tree_structure AS (
    -- Root node
    SELECT
        1::BIGINT AS node_id,
        NULL::BIGINT AS parent_id,
        0 AS depth,
        NULL::TEXT AS split_feature,
        NULL::TEXT AS split_operator,
        NULL::NUMERIC AS split_value_numeric,
        NULL::TEXT AS split_value_text,
        (SELECT target_class 
         FROM (SELECT target_class, COUNT(*) AS cnt 
               FROM cleaned_data 
               GROUP BY target_class 
               ORDER BY cnt DESC 
               LIMIT 1) majority) AS predicted_class,
        '' AS condition_expression,
        ARRAY[]::TEXT[] AS condition_list,
        NULL::TEXT AS split_condition

    UNION ALL

    -- Recursive step to build child nodes
    SELECT
        parent.node_id * 10 + branch.branch,
        parent.node_id,
        parent.depth + 1,
        branch.feature,
        branch.operator,
        branch.value_numeric,
        branch.value_text,
        COALESCE((
            SELECT target_class 
            FROM (
                SELECT target_class, COUNT(*) AS cnt
                FROM cleaned_data
                WHERE
                    -- Apply parent conditions
                    (parent.split_feature IS NULL OR (
                        CASE
                            WHEN parent.split_feature = 'feature_numeric_1' THEN
                                (parent.split_operator = '<=' AND feature_numeric_1 <= parent.split_value_numeric) OR
                                (parent.split_operator = '>' AND feature_numeric_1 > parent.split_value_numeric)
                            WHEN parent.split_feature = 'feature_numeric_2' THEN
                                (parent.split_operator = '<=' AND feature_numeric_2 <= parent.split_value_numeric) OR
                                (parent.split_operator = '>' AND feature_numeric_2 > parent.split_value_numeric)
                            WHEN parent.split_feature = 'feature_categorical_1' THEN
                                (parent.split_operator = '=' AND feature_categorical_1 = parent.split_value_text) OR
                                (parent.split_operator = '!=' AND feature_categorical_1 <> parent.split_value_text)
                            WHEN parent.split_feature = 'feature_categorical_2' THEN
                                (parent.split_operator = '=' AND feature_categorical_2 = parent.split_value_text) OR
                                (parent.split_operator = '!=' AND feature_categorical_2 <> parent.split_value_text)
                        END
                    ))
                    AND (
                        -- Apply current branch condition
                        CASE
                            WHEN branch.feature = 'feature_numeric_1' THEN
                                (branch.operator = '<=' AND feature_numeric_1 <= branch.value_numeric) OR
                                (branch.operator = '>' AND feature_numeric_1 > branch.value_numeric)
                            WHEN branch.feature = 'feature_numeric_2' THEN
                                (branch.operator = '<=' AND feature_numeric_2 <= branch.value_numeric) OR
                                (branch.operator = '>' AND feature_numeric_2 > branch.value_numeric)
                            WHEN branch.feature = 'feature_categorical_1' THEN
                                (branch.operator = '=' AND feature_categorical_1 = branch.value_text) OR
                                (branch.operator = '!=' AND feature_categorical_1 <> branch.value_text)
                            WHEN branch.feature = 'feature_categorical_2' THEN
                                (branch.operator = '=' AND feature_categorical_2 = branch.value_text) OR
                                (branch.operator = '!=' AND feature_categorical_2 <> branch.value_text)
                        END
                    )
                GROUP BY target_class
                ORDER BY cnt DESC
                LIMIT 1
            ) majority
        ), NULL) AS predicted_class,
        CASE
            WHEN parent.condition_expression = '' THEN 
                branch.feature || ' ' || branch.operator || ' ' || COALESCE(branch.value_text, branch.value_numeric::TEXT)
            ELSE 
                parent.condition_expression || ' AND ' || branch.feature || ' ' || branch.operator || ' ' || COALESCE(branch.value_text, branch.value_numeric::TEXT)
        END AS condition_expression,
        parent.condition_list || branch.condition_key,
        branch.feature || ' ' || branch.operator || ' ' || COALESCE(branch.value_text, branch.value_numeric::TEXT) AS split_condition
    FROM tree_structure parent
    JOIN LATERAL (
        -- Compute optimal splits with pre-pruning
        WITH filtered_data AS (
            SELECT * FROM cleaned_data
            WHERE
                parent.split_feature IS NULL OR (
                    CASE
                        WHEN parent.split_feature = 'feature_numeric_1' THEN
                            (parent.split_operator = '<=' AND feature_numeric_1 <= parent.split_value_numeric) OR
                            (parent.split_operator = '>' AND feature_numeric_1 > parent.split_value_numeric)
                        WHEN parent.split_feature = 'feature_numeric_2' THEN
                            (parent.split_operator = '<=' AND feature_numeric_2 <= parent.split_value_numeric) OR
                            (parent.split_operator = '>' AND feature_numeric_2 > parent.split_value_numeric)
                        WHEN parent.split_feature = 'feature_categorical_1' THEN
                            (parent.split_operator = '=' AND feature_categorical_1 = parent.split_value_text) OR
                            (parent.split_operator = '!=' AND feature_categorical_1 <> parent.split_value_text)
                        WHEN parent.split_feature = 'feature_categorical_2' THEN
                            (parent.split_operator = '=' AND feature_categorical_2 = parent.split_value_text) OR
                            (parent.split_operator = '!=' AND feature_categorical_2 <> parent.split_value_text)
                    END
                )
        ),
        node_classes AS (
            SELECT COUNT(DISTINCT target_class) AS num_classes
            FROM filtered_data
        ),
        totals AS (
			SELECT
                SUM(CASE WHEN target_class = 'A' THEN 1 ELSE 0 END) AS total_A,
                COUNT(*) - SUM(CASE WHEN target_class = 'A' THEN 1 ELSE 0 END) AS total_B
            FROM filtered_data
		
                    ),
        all_splits AS (
            SELECT 
                'feature_numeric_1' AS feature, 
                '<=' AS operator, 
                NULL::TEXT AS value_text, 
                feature_numeric_1 AS value_numeric,
                CONCAT('feature_numeric_1|<=|', feature_numeric_1) AS condition_key
            FROM filtered_data
            UNION
            SELECT 
                'feature_numeric_2', 
                '<=', 
                NULL::TEXT, 
                feature_numeric_2,
                CONCAT('feature_numeric_2|<=|', feature_numeric_2) AS condition_key
            FROM filtered_data
            UNION
            SELECT 
                'feature_categorical_1', 
                '=', 
                feature_categorical_1, 
                NULL::NUMERIC,
                CONCAT('feature_categorical_1|=|', feature_categorical_1) AS condition_key
            FROM filtered_data
            UNION
            SELECT 
                'feature_categorical_2', 
                '=', 
                feature_categorical_2, 
                NULL::NUMERIC,
                CONCAT('feature_categorical_2|=|', feature_categorical_2) AS condition_key
            FROM filtered_data
        ),
        gini_calc AS (
            SELECT
                s.feature, 
                s.operator, 
                s.value_text, 
                s.value_numeric,
                s.condition_key,
                SUM(CASE WHEN
                    (s.feature = 'feature_numeric_1' AND f.feature_numeric_1 <= s.value_numeric) OR
                    (s.feature = 'feature_numeric_2' AND f.feature_numeric_2 <= s.value_numeric) OR
                    (s.feature = 'feature_categorical_1' AND f.feature_categorical_1 = s.value_text) OR
                    (s.feature = 'feature_categorical_2' AND f.feature_categorical_2 = s.value_text)
                    THEN CASE WHEN f.target_class = 'A' THEN 1 ELSE 0 END ELSE 0 END) AS left_A,
                SUM(CASE WHEN
                    (s.feature = 'feature_numeric_1' AND f.feature_numeric_1 <= s.value_numeric) OR
                    (s.feature = 'feature_numeric_2' AND f.feature_numeric_2 <= s.value_numeric) OR
                    (s.feature = 'feature_categorical_1' AND f.feature_categorical_1 = s.value_text) OR
                    (s.feature = 'feature_categorical_2' AND f.feature_categorical_2 = s.value_text)
                    THEN CASE WHEN f.target_class = 'B' THEN 1 ELSE 0 END ELSE 0 END) AS left_B,
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
                    (CAST(left_A + left_B AS FLOAT) / NULLIF(total_A + total_B, 0)) *
                    (1.0 - POWER(CAST(left_A AS FLOAT) / NULLIF(left_A + left_B, 0), 2) - 
                           POWER(CAST(left_B AS FLOAT) / NULLIF(left_A + left_B, 0), 2))
                    +
                    (CAST((total_A - left_A) + (total_B - left_B) AS FLOAT) / NULLIF(total_A + total_B, 0)) *
                    (1.0 - POWER(CAST(total_A - left_A AS FLOAT) / NULLIF((total_A - left_A) + (total_B - left_B), 0), 2) - 
                           POWER(CAST(total_B - left_B AS FLOAT) / NULLIF((total_A - left_A) + (total_B - left_B), 0), 2))
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
                        WHEN feature = 'feature_numeric_1' THEN f.feature_numeric_1 <= value_numeric
                        WHEN feature = 'feature_numeric_2' THEN f.feature_numeric_2 <= value_numeric
                        WHEN feature = 'feature_categorical_1' THEN f.feature_categorical_1 = value_text
                        WHEN feature = 'feature_categorical_2' THEN f.feature_categorical_2 = value_text
                    END
            )
            UNION ALL
            SELECT 
                feature,
                CASE WHEN feature IN ('feature_numeric_1', 'feature_numeric_2') THEN '>' ELSE '!=' END,
                value_text,
                value_numeric,
                CONCAT(feature, '|', 
                       CASE WHEN feature IN ('feature_numeric_1', 'feature_numeric_2') THEN '>' ELSE '!=' END, 
                       '|', COALESCE(value_text, value_numeric::TEXT)) AS condition_key,
                2 AS branch
            FROM best_split
            WHERE EXISTS (
                SELECT 1 FROM filtered_data f WHERE
                    NOT (
                        CASE
                            WHEN feature = 'feature_numeric_1' THEN f.feature_numeric_1 <= value_numeric
                            WHEN feature = 'feature_numeric_2' THEN f.feature_numeric_2 <= value_numeric
                            WHEN feature = 'feature_categorical_1' THEN f.feature_categorical_1 = value_text
                            WHEN feature = 'feature_categorical_2' THEN f.feature_categorical_2 = value_text
                        END
                    )
            )
        )
        SELECT * FROM make_branches
        WHERE (SELECT num_classes FROM node_classes) > 1
    ) branch ON parent.depth < 3
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