use anyhow::Result;
use std::io::{self, BufWriter, Write};

/// Buffered output writer for efficient terminal output
///
/// This struct wraps any writer (typically stdout) with a BufWriter
/// to improve performance by reducing the number of system calls.
pub struct BufferedOutput<W: Write> {
    writer: BufWriter<W>,
}

impl<W: Write> BufferedOutput<W> {
    /// Creates a new BufferedOutput with default buffer size (8KB)
    pub fn new(writer: W) -> Self {
        Self {
            writer: BufWriter::new(writer),
        }
    }

    /// Creates a new BufferedOutput with specified buffer capacity
    pub fn with_capacity(capacity: usize, writer: W) -> Self {
        Self {
            writer: BufWriter::with_capacity(capacity, writer),
        }
    }

    /// Writes a line to the buffered output
    pub fn writeln(&mut self, content: &str) -> Result<()> {
        writeln!(self.writer, "{}", content)?;
        Ok(())
    }

    /// Writes content without a newline
    pub fn write(&mut self, content: &str) -> Result<()> {
        write!(self.writer, "{}", content)?;
        Ok(())
    }

    /// Writes a newline only
    pub fn newline(&mut self) -> Result<()> {
        writeln!(self.writer)?;
        Ok(())
    }

    /// Flushes the buffer to ensure all content is written
    pub fn flush(&mut self) -> Result<()> {
        self.writer.flush()?;
        Ok(())
    }

    /// Gets a mutable reference to the underlying writer
    pub fn get_mut(&mut self) -> &mut BufWriter<W> {
        &mut self.writer
    }

    /// Consumes the BufferedOutput and returns the underlying writer
    pub fn into_inner(self) -> Result<W> {
        self.writer
            .into_inner()
            .map_err(|e| anyhow::anyhow!("Failed to flush and unwrap writer: {}", e))
    }
}

/// Default implementation for stdout
impl BufferedOutput<io::Stdout> {
    /// Creates a BufferedOutput for stdout
    pub fn stdout() -> Self {
        Self::new(io::stdout())
    }

    /// Creates a BufferedOutput for stdout with specified buffer capacity
    pub fn stdout_with_capacity(capacity: usize) -> Self {
        Self::with_capacity(capacity, io::stdout())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    struct MockWriter {
        buffer: Arc<Mutex<Vec<u8>>>,
    }

    impl MockWriter {
        fn new() -> (Self, Arc<Mutex<Vec<u8>>>) {
            let buffer = Arc::new(Mutex::new(Vec::new()));
            (
                MockWriter {
                    buffer: Arc::clone(&buffer),
                },
                buffer,
            )
        }
    }

    impl Write for MockWriter {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            let mut buffer = self.buffer.lock().unwrap();
            buffer.extend_from_slice(buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn test_buffered_output_writeln() {
        let (mock_writer, buffer_ref) = MockWriter::new();
        let mut output = BufferedOutput::new(mock_writer);

        output.writeln("Hello, World!").unwrap();
        output.writeln("Second line").unwrap();
        output.flush().unwrap();

        let buffer = buffer_ref.lock().unwrap();
        let result = String::from_utf8_lossy(&buffer);
        assert_eq!(result, "Hello, World!\nSecond line\n");
    }

    #[test]
    fn test_buffered_output_write() {
        let (mock_writer, buffer_ref) = MockWriter::new();
        let mut output = BufferedOutput::new(mock_writer);

        output.write("Hello").unwrap();
        output.write(", ").unwrap();
        output.write("World!").unwrap();
        output.newline().unwrap();
        output.flush().unwrap();

        let buffer = buffer_ref.lock().unwrap();
        let result = String::from_utf8_lossy(&buffer);
        assert_eq!(result, "Hello, World!\n");
    }

    #[test]
    fn test_buffered_output_with_capacity() {
        let (mock_writer, buffer_ref) = MockWriter::new();
        let mut output = BufferedOutput::with_capacity(1024, mock_writer);

        for i in 0..10 {
            output.writeln(&format!("Line {}", i)).unwrap();
        }
        output.flush().unwrap();

        let buffer = buffer_ref.lock().unwrap();
        let result = String::from_utf8_lossy(&buffer);
        let lines: Vec<&str> = result.lines().collect();
        assert_eq!(lines.len(), 10);
        assert_eq!(lines[0], "Line 0");
        assert_eq!(lines[9], "Line 9");
    }
}
