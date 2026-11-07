# Dynamic Data Preprocessing & Decision Tree Framework

A PostgreSQL-based project focused on dynamic data preprocessing, automatic feature type detection, and database design for decision tree modeling.

## Overview

This project explores how raw tabular data can be processed dynamically using SQL and PL/pgSQL. It provides a framework for identifying numeric and categorical features, managing feature metadata, and preparing structured data for machine learning workflows.

The project also introduces a database schema for representing decision trees and storing model evaluation metrics.

## Key Features

- **Dynamic Feature Detection:** Automatically identifies numeric and categorical columns based on their data values.
- **Metadata Management:** Maintains feature information, data types, and target variable identification.
- **Data Preprocessing:** Converts and prepares raw input data for downstream analysis.
- **Decision Tree Schema:** Defines database structures for tree nodes, parent-child relationships, and splitting conditions.
- **Model Evaluation:** Provides tables for storing Gini impurity, information gain, accuracy, precision, recall, and F1-score.
- **Database Optimization:** Uses indexing to improve query performance.

## Technologies

- PostgreSQL
- SQL
- PL/pgSQL
- JSONB
- Dynamic SQL

## Project Architecture

1. Raw data ingestion into a staging table.
2. Automatic feature type detection.
3. Feature metadata generation.
4. Dynamic data preprocessing.
5. Decision tree schema design.
6. Model metrics and validation result storage.

## Database Components

| Component | Description |
|---|---|
| `raw_input` | Stores raw input data |
| `metadata_features` | Stores detected feature metadata |
| `features_input` | Stores processed input data |
| `model_tree` | Represents decision tree nodes |
| `tree_metrics` | Stores tree-related metrics |
| `model_metrics` | Stores model evaluation metrics |
| `data_statistics` | Stores statistical information |
| `model_validation_results` | Stores validation results |

## Getting Started

### Requirements
- PostgreSQL
- pgAdmin, DBeaver, or psql

### Execution

1. Create a PostgreSQL database.
2. Open `solved_final.sql`.
3. Review the SQL script, especially the `DROP TABLE CASCADE` statements.
4. Execute the script in your development database.

## Future Improvements

- Complete recursive decision tree construction.
- Implement numeric and categorical split optimization.
- Improve missing-value handling.
- Add automated model validation.
- Implement feature importance calculations.
- Add comprehensive SQL testing.

## Author

**Amir Mohammad Najafi**

**Interests:** Machine Learning | Data Engineering | Database Systems | Artificial Intelligence
