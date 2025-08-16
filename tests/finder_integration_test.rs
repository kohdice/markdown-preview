use std::env;
use std::fs;
use std::process::Command;
use tempfile::TempDir;

#[test]
fn test_mp_without_args_lists_markdown_files() {
    let temp_dir = TempDir::new().unwrap();

    fs::write(temp_dir.path().join("README.md"), "# Test").unwrap();
    fs::write(temp_dir.path().join("doc.md"), "Documentation").unwrap();
    fs::write(temp_dir.path().join("test.txt"), "Not markdown").unwrap();

    // Subdirectory and files
    let sub_dir = temp_dir.path().join("docs");
    fs::create_dir(&sub_dir).unwrap();
    fs::write(sub_dir.join("api.md"), "API docs").unwrap();

    let mp_path = env::current_exe()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("mp");

    let output = Command::new(&mp_path)
        .current_dir(temp_dir.path())
        .output()
        .expect("Failed to execute mp command");

    // Debug output
    if !output.status.success() {
        eprintln!(
            "Command failed with stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);

    assert!(stdout.contains("README.md"));
    assert!(stdout.contains("doc.md"));
    assert!(stdout.contains("docs/api.md"));

    assert!(!stdout.contains("test.txt"));
}

#[test]
fn test_mp_with_file_arg_previews_file() {
    let temp_dir = TempDir::new().unwrap();
    let test_file = temp_dir.path().join("test.md");
    fs::write(&test_file, "# Test Header\n\nTest content").unwrap();

    let mp_path = env::current_exe()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("mp");

    let output = Command::new(&mp_path)
        .arg(test_file.to_str().unwrap())
        .output()
        .expect("Failed to execute mp command");

    let stdout = String::from_utf8_lossy(&output.stdout);

    assert!(stdout.contains("Test Header") || stdout.contains("\x1b["));
    assert!(stdout.contains("Test content") || stdout.contains("\x1b["));
}

#[test]
fn test_mp_with_hidden_flag() {
    let temp_dir = TempDir::new().unwrap();

    fs::write(temp_dir.path().join("visible.md"), "Visible").unwrap();
    fs::write(temp_dir.path().join(".hidden.md"), "Hidden").unwrap();

    let mp_path = env::current_exe()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("mp");

    let output = Command::new(&mp_path)
        .current_dir(temp_dir.path())
        .output()
        .expect("Failed to execute mp command");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("visible.md"));
    assert!(!stdout.contains(".hidden.md"));

    // With --hidden flag (show hidden files)
    let output = Command::new(&mp_path)
        .arg("--hidden")
        .current_dir(temp_dir.path())
        .output()
        .expect("Failed to execute mp command");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("visible.md"));
    assert!(stdout.contains(".hidden.md"));
}

#[test]
fn test_mp_with_gitignore() {
    let temp_dir = TempDir::new().unwrap();

    // Initialize as git repository (required for .gitignore to work)
    Command::new("git")
        .args(["init"])
        .current_dir(temp_dir.path())
        .output()
        .expect("Failed to init git repo");

    fs::write(temp_dir.path().join(".gitignore"), "ignored.md\n").unwrap();

    fs::write(temp_dir.path().join("visible.md"), "Visible").unwrap();
    fs::write(temp_dir.path().join("ignored.md"), "Ignored").unwrap();

    let mp_path = env::current_exe()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("mp");

    let output = Command::new(&mp_path)
        .current_dir(temp_dir.path())
        .output()
        .expect("Failed to execute mp command");

    let stdout = String::from_utf8_lossy(&output.stdout);

    // Debug output
    eprintln!("Output with .gitignore: '{}'", stdout);
    eprintln!(
        "Files in dir: {:?}",
        fs::read_dir(temp_dir.path()).unwrap().collect::<Vec<_>>()
    );

    assert!(stdout.contains("visible.md"));
    assert!(!stdout.contains("ignored.md"));

    // With --no-ignore flag (ignore .gitignore)
    let output = Command::new(&mp_path)
        .arg("--no-ignore")
        .current_dir(temp_dir.path())
        .output()
        .expect("Failed to execute mp command");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("visible.md"));
    assert!(stdout.contains("ignored.md"));
}

#[test]
fn test_mp_with_mpignore() {
    let temp_dir = TempDir::new().unwrap();

    fs::write(temp_dir.path().join(".mpignore"), "temp.md\n").unwrap();

    fs::write(temp_dir.path().join("keep.md"), "Keep").unwrap();
    fs::write(temp_dir.path().join("temp.md"), "Temporary").unwrap();

    let mp_path = env::current_exe()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("mp");

    let output = Command::new(&mp_path)
        .current_dir(temp_dir.path())
        .output()
        .expect("Failed to execute mp command");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("keep.md"));
    assert!(!stdout.contains("temp.md"));
}
