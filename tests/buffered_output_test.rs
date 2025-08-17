use std::io::{BufWriter, Write};
use std::sync::{Arc, Mutex};

/// テスト用のモックライター
#[derive(Debug)]
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

    fn get_output(&self) -> String {
        let buffer = self.buffer.lock().unwrap();
        String::from_utf8_lossy(&buffer).to_string()
    }
}

impl Write for MockWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let mut buffer = self.buffer.lock().unwrap();
        buffer.extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[test]
fn test_buffered_writer_basic() {
    let (mock_writer, _) = MockWriter::new();
    let mut buffered = BufWriter::new(mock_writer);

    // 複数の小さな書き込み
    writeln!(buffered, "Line 1").unwrap();
    writeln!(buffered, "Line 2").unwrap();
    writeln!(buffered, "Line 3").unwrap();

    // フラッシュして出力を確認
    buffered.flush().unwrap();

    let mock_writer = buffered.into_inner().unwrap();
    let output = mock_writer.get_output();
    assert_eq!(output, "Line 1\nLine 2\nLine 3\n");
}

#[test]
fn test_buffered_writer_performance() {
    let (mock_writer, buffer_ref) = MockWriter::new();
    let mut buffered = BufWriter::with_capacity(8192, mock_writer);

    // 大量の小さな書き込み（バッファリングされる）
    for i in 0..100 {
        writeln!(buffered, "Line {}", i).unwrap();
    }

    // フラッシュ前：バッファは空（まだ書き込まれていない）
    {
        let buffer = buffer_ref.lock().unwrap();
        assert!(buffer.is_empty() || buffer.len() < 8192);
    }

    // フラッシュ後：全てのデータが書き込まれる
    buffered.flush().unwrap();
    let mock_writer = buffered.into_inner().unwrap();
    let output = mock_writer.get_output();

    let lines: Vec<&str> = output.lines().collect();
    assert_eq!(lines.len(), 100);
    assert_eq!(lines[0], "Line 0");
    assert_eq!(lines[99], "Line 99");
}

#[test]
fn test_buffered_writer_auto_flush() {
    let (mock_writer, _) = MockWriter::new();
    let mut buffered = BufWriter::with_capacity(64, mock_writer); // 小さなバッファ

    // バッファサイズを超える書き込み（自動フラッシュ）
    let long_string = "a".repeat(100);
    writeln!(buffered, "{}", long_string).unwrap();

    buffered.flush().unwrap();
    let mock_writer = buffered.into_inner().unwrap();
    let output = mock_writer.get_output();
    assert!(output.starts_with(&long_string));
}
