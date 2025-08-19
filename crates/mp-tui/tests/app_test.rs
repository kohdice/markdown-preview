use mp_tui::{App, Focus};

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
    assert_eq!(app.focus, Focus::FileTree);
}

#[test]
fn test_app_quit_handling() {
    let mut app = App::new().expect("Failed to create app");

    let quit_key = crossterm::event::KeyEvent::new(
        crossterm::event::KeyCode::Char('q'),
        crossterm::event::KeyModifiers::NONE,
    );

    let should_quit = app.handle_key(quit_key).expect("Failed to handle key");
    assert!(should_quit);
    assert!(app.should_quit);
}
