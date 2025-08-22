//! Table builder module for constructing tables with fluent API

use std::fmt;

use anyhow::Result;
use pulldown_cmark::Alignment;

/// A builder for constructing tables with a fluent API
///
/// # Example
/// ```
/// use mp_stdout::TableBuilder;
/// use pulldown_cmark::Alignment;
///
/// let table = TableBuilder::new()
///     .header(vec!["Name", "Age", "City"])
///     .alignments(vec![Alignment::Left, Alignment::Right, Alignment::Center])
///     .row(vec!["Alice", "30", "New York"])
///     .row(vec!["Bob", "25", "London"])
///     .build()
///     .expect("Failed to build table");
/// ```
#[derive(Debug, Clone)]
pub struct TableBuilder {
    headers: Option<Vec<String>>,
    rows: Vec<Vec<String>>,
    alignments: Vec<Alignment>,
    separator: &'static str,
    alignment_config: TableAlignmentConfig,
}

/// Configuration for table alignment indicators
#[derive(Debug, Clone)]
pub struct TableAlignmentConfig {
    pub left: &'static str,
    pub center: &'static str,
    pub right: &'static str,
    pub none: &'static str,
}

impl Default for TableAlignmentConfig {
    fn default() -> Self {
        Self {
            left: ":---",
            center: ":---:",
            right: "---:",
            none: "---",
        }
    }
}

/// Represents a built table ready for rendering
#[derive(Debug, Clone)]
pub struct Table {
    headers: Option<Vec<String>>,
    rows: Vec<Vec<String>>,
    alignments: Vec<Alignment>,
    separator: &'static str,
    alignment_config: TableAlignmentConfig,
}

impl TableBuilder {
    /// Creates a new table builder with default settings
    pub fn new() -> Self {
        Self {
            headers: None,
            rows: Vec::with_capacity(10), // Pre-allocate for typical table size
            alignments: Vec::with_capacity(5), // Tables typically have 2-5 columns
            separator: "|",
            alignment_config: TableAlignmentConfig::default(),
        }
    }

    /// Sets the header row
    pub fn header<I, S>(mut self, headers: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let header_vec: Vec<String> = headers.into_iter().map(|s| s.into()).collect();
        let column_count = header_vec.len();

        // Auto-generate alignments if not set
        if self.alignments.is_empty() {
            self.alignments = vec![Alignment::None; column_count];
        }

        self.headers = Some(header_vec);
        self
    }

    /// Sets column alignments
    pub fn alignments(mut self, alignments: Vec<Alignment>) -> Self {
        self.alignments = alignments;
        self
    }

    /// Adds a data row
    pub fn row<I, S>(mut self, row: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.rows.push(row.into_iter().map(|s| s.into()).collect());
        self
    }

    /// Adds multiple rows at once
    pub fn rows<I, R, S>(mut self, rows: I) -> Self
    where
        I: IntoIterator<Item = R>,
        R: IntoIterator<Item = S>,
        S: Into<String>,
    {
        for row in rows {
            self.rows.push(row.into_iter().map(|s| s.into()).collect());
        }
        self
    }

    /// Sets a custom separator character
    pub fn separator(mut self, separator: &'static str) -> Self {
        self.separator = separator;
        self
    }

    /// Sets custom alignment configuration
    pub fn alignment_config(mut self, config: TableAlignmentConfig) -> Self {
        self.alignment_config = config;
        self
    }

    /// Validates the table structure
    fn validate(&self) -> Result<()> {
        let column_count = if let Some(ref headers) = self.headers {
            headers.len()
        } else if !self.rows.is_empty() {
            self.rows[0].len()
        } else {
            return Ok(());
        };

        for (i, row) in self.rows.iter().enumerate() {
            if row.len() != column_count {
                return Err(anyhow::anyhow!(
                    "Row {} has {} columns, expected {}",
                    i,
                    row.len(),
                    column_count
                ));
            }
        }

        if !self.alignments.is_empty() && self.alignments.len() != column_count {
            return Err(anyhow::anyhow!(
                "Alignment count ({}) doesn't match column count ({})",
                self.alignments.len(),
                column_count
            ));
        }

        Ok(())
    }

    /// Builds the table, returning an error if validation fails
    pub fn build(self) -> Result<Table> {
        self.validate()?;

        Ok(Table {
            headers: self.headers,
            rows: self.rows,
            alignments: self.alignments,
            separator: self.separator,
            alignment_config: self.alignment_config,
        })
    }
}

impl Default for TableBuilder {
    fn default() -> Self {
        Self::new()
    }
}

impl Table {
    /// Gets the headers if present
    pub fn headers(&self) -> Option<&Vec<String>> {
        self.headers.as_ref()
    }

    /// Gets the data rows
    pub fn rows(&self) -> &Vec<Vec<String>> {
        &self.rows
    }

    /// Gets the column alignments
    pub fn alignments(&self) -> &Vec<Alignment> {
        &self.alignments
    }

    /// Helper function to format table row with common logic
    fn format_table_row<I, F>(&self, items: I, formatter: F, estimated_cell_size: usize) -> String
    where
        I: IntoIterator,
        I::IntoIter: ExactSizeIterator,
        F: Fn(&mut String, I::Item),
    {
        let items_iter = items.into_iter();
        let item_count = items_iter.len();
        let estimated_size =
            item_count * estimated_cell_size + self.separator.len() * (item_count + 1);
        let mut output = String::with_capacity(estimated_size);

        output.push_str(self.separator);
        for item in items_iter {
            output.push(' ');
            formatter(&mut output, item);
            output.push(' ');
            output.push_str(self.separator);
        }

        output
    }

    /// Renders a single row as a string
    pub fn render_row(&self, row: &[String]) -> String {
        let avg_cell_size = if row.is_empty() {
            4
        } else {
            row.iter().map(|s| s.len()).sum::<usize>() / row.len() + 4
        };

        self.format_table_row(
            row.iter(),
            |output, cell| output.push_str(cell),
            avg_cell_size,
        )
    }

    /// Renders the alignment separator row
    pub fn render_separator(&self) -> String {
        self.format_table_row(
            &self.alignments,
            |output, alignment| {
                let sep = match alignment {
                    Alignment::Left => &self.alignment_config.left,
                    Alignment::Center => &self.alignment_config.center,
                    Alignment::Right => &self.alignment_config.right,
                    Alignment::None => &self.alignment_config.none,
                };
                output.push_str(sep);
            },
            8,
        )
    }

    /// Renders the entire table
    pub fn render(&self) -> Vec<String> {
        let estimated_lines = if self.headers.is_some() { 2 } else { 0 } + self.rows.len();
        let mut lines = Vec::with_capacity(estimated_lines);

        // Render header if present
        if let Some(ref headers) = self.headers {
            lines.push(self.render_row(headers));
            lines.push(self.render_separator());
        }

        for row in &self.rows {
            lines.push(self.render_row(row));
        }

        lines
    }

    /// Gets the column count
    pub fn column_count(&self) -> usize {
        if let Some(ref headers) = self.headers {
            headers.len()
        } else if !self.rows.is_empty() {
            self.rows[0].len()
        } else {
            0
        }
    }

    /// Gets the row count (excluding header)
    pub fn row_count(&self) -> usize {
        self.rows.len()
    }
}

impl fmt::Display for Table {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for line in self.render() {
            writeln!(f, "{}", line)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Helper function to create a basic table with default configuration
    fn create_test_table() -> TableBuilder {
        TableBuilder::new()
    }

    // Helper function to create a table with header and rows
    fn create_table_with_data(header: Vec<&str>, rows: Vec<Vec<&str>>) -> Result<Table> {
        let mut builder = TableBuilder::new().header(header);
        for row in rows {
            builder = builder.row(row);
        }
        builder.build()
    }

    // Helper function to assert table dimensions
    fn assert_table_dimensions(table: &Table, expected_columns: usize, expected_rows: usize) {
        assert_eq!(table.column_count(), expected_columns);
        assert_eq!(table.row_count(), expected_rows);
    }

    // Helper function to verify alignments
    fn assert_alignments(table: &Table, expected: Vec<Alignment>) {
        let alignments = table.alignments();
        assert_eq!(alignments.len(), expected.len());
        for (actual, expected) in alignments.iter().zip(expected.iter()) {
            assert_eq!(actual, expected);
        }
    }

    #[test]
    fn test_basic_table_builder() {
        let table = create_table_with_data(
            vec!["Name", "Age"],
            vec![vec!["Alice", "30"], vec!["Bob", "25"]],
        )
        .unwrap();

        assert_table_dimensions(&table, 2, 2);
        assert!(table.headers().is_some());
    }

    #[test]
    fn test_table_without_header() {
        let table = create_test_table()
            .row(vec!["A", "B", "C"])
            .row(vec!["D", "E", "F"])
            .build()
            .unwrap();

        assert_table_dimensions(&table, 3, 2);
        assert!(table.headers().is_none());
    }

    #[test]
    fn test_table_with_alignments() {
        let table = create_test_table()
            .header(vec!["Left", "Center", "Right"])
            .alignments(vec![Alignment::Left, Alignment::Center, Alignment::Right])
            .row(vec!["A", "B", "C"])
            .build()
            .unwrap();

        assert_alignments(
            &table,
            vec![Alignment::Left, Alignment::Center, Alignment::Right],
        );
    }

    #[test]
    fn test_table_validation_column_mismatch() {
        let result = create_test_table()
            .header(vec!["A", "B"])
            .row(vec!["1", "2", "3"]) // Too many columns
            .build();

        assert!(result.is_err());
    }

    #[test]
    fn test_table_validation_alignment_mismatch() {
        let result = create_test_table()
            .header(vec!["A", "B", "C"])
            .alignments(vec![Alignment::Left, Alignment::Right]) // Too few alignments
            .build();

        assert!(result.is_err());
    }

    #[test]
    fn test_custom_separator() {
        let table = create_test_table()
            .separator("||")
            .header(vec!["A", "B"])
            .row(vec!["1", "2"])
            .build()
            .unwrap();

        let rendered = table.render_row(&["X".to_string(), "Y".to_string()]);
        assert!(rendered.starts_with("||"));
        assert!(rendered.contains("|| X ||"));
    }

    #[test]
    fn test_empty_table() {
        let table = create_test_table().build().unwrap();
        assert_table_dimensions(&table, 0, 0);
    }

    #[test]
    fn test_table_rendering() {
        let table = create_test_table()
            .header(vec!["Name", "Value"])
            .alignments(vec![Alignment::Left, Alignment::Right])
            .row(vec!["foo", "123"])
            .row(vec!["bar", "456"])
            .build()
            .unwrap();

        let lines = table.render();
        assert_eq!(lines.len(), 4); // header + separator + 2 rows
        assert!(lines[0].contains("Name"));
        assert!(lines[0].contains("Value"));
        assert!(lines[1].contains(":---")); // Left alignment
        assert!(lines[1].contains("---:")); // Right alignment
    }

    #[test]
    fn test_builder_method_chaining() {
        let _table = create_test_table()
            .separator("!")
            .header(vec!["A"])
            .alignments(vec![Alignment::Center])
            .row(vec!["1"])
            .row(vec!["2"])
            .rows(vec![vec!["3"], vec!["4"]])
            .build()
            .unwrap();
    }

    #[test]
    fn test_auto_alignment_generation() {
        let table = create_table_with_data(vec!["A", "B", "C"], vec![vec!["1", "2", "3"]]).unwrap();

        let alignments = table.alignments();
        assert_eq!(alignments.len(), 3);
        assert!(alignments.iter().all(|a| *a == Alignment::None));
    }
}
