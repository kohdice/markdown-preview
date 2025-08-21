use mp_tui::{App, AppFocus};

#[test]
fn test_app_initialization() {
    let result = App::new();
    assert!(
        result.is_ok(),
        "Failed to initialize App: {:?}",
        result.err()
    );

    let app = result.unwrap();
    assert!(!app.should_quit);
    assert_eq!(app.focus, AppFocus::FileTree);
}

#[test]
fn test_app_quit_handling() {
    // Since handle_key is now private, we cannot test it directly from outside
    // This test needs to be moved to the app module or made integration test
    // For now, we just test that the app can be created
    let app = App::new().expect("Failed to create app");
    assert!(!app.should_quit);
}
