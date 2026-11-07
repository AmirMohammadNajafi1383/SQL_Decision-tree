-- Drop existing tables to start fresh
DROP TABLE IF EXISTS raw_input CASCADE;
DROP TABLE IF EXISTS features_input CASCADE;
DROP TABLE IF EXISTS model_tree CASCADE;
DROP TABLE IF EXISTS metadata_features CASCADE;
DROP TABLE IF EXISTS model_metrics CASCADE;
DROP TABLE IF EXISTS tree_metrics CASCADE;
DROP TABLE IF EXISTS data_statistics CASCADE;
DROP TABLE IF EXISTS model_validation_results CASCADE;

-- Step 1: Create a staging table to simulate loading raw text data
CREATE TABLE raw_input (
    "feature numeric 1" TEXT,
    "feature numeric 2" TEXT,
    "feature categorical 1" TEXT,
    "feature categorical 2" TEXT,
    "target class" TEXT
);

-- Step 2: Insert sample data
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

-- Step 3: Create function for dynamic data type detection
CREATE OR REPLACE FUNCTION detect_column_type(p_table_name TEXT, p_column_name TEXT) 
RETURNS TEXT AS $$
DECLARE
    v_is_numeric BOOLEAN;
    v_distinct_count INT;
    v_total_count INT;
    v_numeric_count INT;
    v_threshold NUMERIC := 0.8;
BEGIN
    EXECUTE format('
        SELECT 
            COUNT(*) FILTER (WHERE %I ~ ''^[0-9]+(\.[0-9]+)?$'')::NUMERIC / NULLIF(COUNT(*), 0) > $1,
            COUNT(DISTINCT %I),
            COUNT(*),
            COUNT(*) FILTER (WHERE %I ~ ''^[0-9]+(\.[0-9]+)?$'')
        FROM %I
        WHERE %I IS NOT NULL',
        p_column_name, p_column_name, p_column_name, p_table_name, p_column_name)
    INTO v_is_numeric, v_distinct_count, v_total_count, v_numeric_count;

    RETURN CASE
        WHEN v_is_numeric AND (v_numeric_count::NUMERIC / NULLIF(v_total_count, 0)) >= v_threshold THEN 'numeric'
        WHEN v_distinct_count::NUMERIC / NULLIF(v_total_count, 0) <= 0.1 THEN 'categorical'
        ELSE 'categorical'
    END;
END;
$$ LANGUAGE plpgsql;

-- Step 4: Create metadata table with dynamic type detection
CREATE TABLE metadata_features (
    "feature name" TEXT PRIMARY KEY,
    "feature type" TEXT,
    "is_target" BOOLEAN DEFAULT FALSE,
    "last_updated" TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Step 5: Create function to update metadata
CREATE OR REPLACE FUNCTION update_metadata_features() 
RETURNS VOID AS $$
DECLARE
    v_column RECORD;
BEGIN
    TRUNCATE TABLE metadata_features;
    
    FOR v_column IN 
        SELECT column_name 
        FROM information_schema.columns 
        WHERE table_name = 'raw_input'
    LOOP
        INSERT INTO metadata_features ("feature name", "feature type", "is_target")
        VALUES (
            v_column.column_name,
            detect_column_type('raw_input', v_column.column_name),
            v_column.column_name = '"target class"'
        );
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Step 6: Create main input table with dynamic structure
CREATE TABLE features_input (
    LIKE raw_input INCLUDING ALL
);

-- Step 7: Create function for dynamic data conversion
CREATE OR REPLACE FUNCTION convert_column_to_proper_type(
    p_table_name TEXT,
    p_column_name TEXT,
    p_target_type TEXT
) RETURNS VOID AS $$
BEGIN
    EXECUTE format('
        CREATE TABLE temp_converted AS
        SELECT 
            %I,
            CASE 
                WHEN $1 = ''numeric'' THEN 
                    CASE 
                        WHEN %I ~ ''^[0-9]+(\.[0-9]+)?$'' THEN 
                            CAST(%I AS NUMERIC)
                        ELSE NULL 
                    END
                ELSE 
                    %I::TEXT 
            END as converted_value
        FROM %I',
        p_column_name, p_column_name, p_column_name, p_table_name);
    
    EXECUTE format('
        UPDATE %I t
        SET %I = tc.converted_value
        FROM temp_converted tc
        WHERE t.ctid = tc.ctid',
        p_table_name, p_column_name);
    
    DROP TABLE temp_converted;
END;
$$ LANGUAGE plpgsql;

-- Step 8: Create main processing function
CREATE OR REPLACE FUNCTION process_input_data_dynamically() 
RETURNS VOID AS $$
DECLARE
    v_column RECORD;
BEGIN
    -- Update metadata
    PERFORM update_metadata_features();
    
    -- Create features_input table with proper structure
    DROP TABLE IF EXISTS features_input;
    CREATE TABLE features_input (LIKE raw_input INCLUDING ALL);
    
    -- Copy data
    INSERT INTO features_input SELECT * FROM raw_input;
    
    -- Process each column
    FOR v_column IN 
        SELECT "feature name", "feature type"
        FROM metadata_features
        WHERE NOT "is_target"
    LOOP
        PERFORM convert_column_to_proper_type(
            'features_input',
            v_column."feature name",
            v_column."feature type"
        );
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Step 9: Create metrics table
CREATE TABLE model_metrics (
    metric_name TEXT,
    metric_value NUMERIC,
    node_id BIGINT,
    depth INT
);

-- Step 10: Create tree metrics table
CREATE TABLE tree_metrics (
    metric_id SERIAL PRIMARY KEY,
    node_id BIGINT,
    depth INT,
    gini_impurity NUMERIC,
    information_gain NUMERIC,
    sample_count INT,
    class_distribution JSONB,
    feature_importance NUMERIC,
    parent_gini NUMERIC,
    child_gini NUMERIC,
    split_quality NUMERIC,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Step 11: Create data statistics table
CREATE TABLE data_statistics (
    feature_name TEXT PRIMARY KEY,
    min_value NUMERIC,
    max_value NUMERIC,
    mean_value NUMERIC,
    std_dev NUMERIC,
    distinct_values INT,
    null_count INT,
    last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Step 12: Create validation results table
CREATE TABLE model_validation_results (
    validation_id SERIAL PRIMARY KEY,
    node_id BIGINT,
    depth INT,
    accuracy NUMERIC,
    precision NUMERIC,
    recall NUMERIC,
    f1_score NUMERIC,
    confusion_matrix JSONB,
    validation_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Step 13: Create tree structure table
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
    split_condition TEXT,
    feature_type TEXT,
    gini_impurity NUMERIC,
    sample_count INT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Step 14: Create function for building decision tree
CREATE OR REPLACE FUNCTION build_decision_tree() 
RETURNS VOID AS $$
DECLARE
    v_node RECORD;
    v_feature_type TEXT;
    v_split_value NUMERIC;
    v_split_text TEXT;
    v_gini_score NUMERIC;
BEGIN
    -- Clear existing tree
    TRUNCATE TABLE model_tree;
    
    -- Insert root node
    INSERT INTO model_tree (
        node_id, parent_id, depth, 
        split_feature, split_operator, 
        split_value_numeric, split_value_text,
        predicted_class, condition_expression,
        split_condition, feature_type,
        gini_impurity, sample_count
    )
    SELECT 
        1, NULL, 0,
        NULL, NULL,
        NULL, NULL,
        (SELECT "target class" 
         FROM (SELECT "target class", COUNT(*) as cnt 
               FROM features_input 
               GROUP BY "target class" 
               ORDER BY cnt DESC 
               LIMIT 1) majority),
        '',
        NULL,
        NULL,
        (SELECT 1.0 - SUM(POWER(cnt::NUMERIC / total, 2))
         FROM (
             SELECT COUNT(*) as cnt,
                    COUNT(*) OVER () as total
             FROM features_input
             GROUP BY "target class"
         ) class_counts),
        COUNT(*)
    FROM features_input;

    -- Build tree recursively
    FOR v_node IN 
        SELECT * FROM model_tree 
        WHERE depth < 10 
        AND predicted_class IS NULL
    LOOP
        -- Get feature type
        SELECT "feature type" INTO v_feature_type
        FROM metadata_features
        WHERE "feature name" = v_node.split_feature;

        -- Find best split based on feature type
        IF v_feature_type = 'numeric' THEN
            SELECT * INTO v_split_value, v_gini_score
            FROM find_best_numeric_split(v_node.split_feature);
        ELSE
            SELECT * INTO v_split_text, v_gini_score
            FROM find_best_categorical_split(v_node.split_feature);
        END IF;

        -- Insert child nodes
        -- ... (ادامه منطق تقسیم‌بندی)
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Step 15: Execute dynamic processing
SELECT process_input_data_dynamically();

-- Step 16: Create indexes for better performance
CREATE INDEX idx_features_input_numeric1 ON features_input ("feature numeric 1");
CREATE INDEX idx_features_input_numeric2 ON features_input ("feature numeric 2");
CREATE INDEX idx_features_input_categorical1 ON features_input ("feature categorical 1");
CREATE INDEX idx_features_input_categorical2 ON features_input ("feature categorical 2");
CREATE INDEX idx_model_tree_node_id ON model_tree(node_id);
CREATE INDEX idx_model_tree_parent_id ON model_tree(parent_id);
CREATE INDEX idx_tree_metrics_node_id ON tree_metrics(node_id);
CREATE INDEX idx_model_validation_results_node_id ON model_validation_results(node_id);