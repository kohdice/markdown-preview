use criterion::{BenchmarkId, Criterion, black_box, criterion_group, criterion_main};
use mp_tui::renderer::MarkdownWidget as RendererStandard;
use mp_tui::renderer_optimized::MarkdownWidget as RendererOptimized;

const SMALL_MD: &str = r#"
# Small Test Document

This is a **bold** text and this is *italic* text.

## Code Example

```rust
fn main() {
    println!("Hello, world!");
}
```

### List Example

- Item 1
- Item 2
  - Nested item
- Item 3

[Link to example](https://example.com)
"#;

const MEDIUM_MD: &str = r#"
# Medium Test Document

This document contains more content to test performance.

## Introduction

Lorem ipsum dolor sit amet, consectetur adipiscing elit. **Bold text** and *italic text* are used throughout.

### Code Blocks

```rust
fn complex_function(input: Vec<i32>) -> Vec<i32> {
    input.iter()
        .filter(|&x| x % 2 == 0)
        .map(|x| x * 2)
        .collect()
}
```

```python
def process_data(data):
    return [x * 2 for x in data if x % 2 == 0]
```

## Tables

| Header 1 | Header 2 | Header 3 |
|----------|----------|----------|
| Cell 1   | Cell 2   | Cell 3   |
| Cell 4   | Cell 5   | Cell 6   |
| Cell 7   | Cell 8   | Cell 9   |

## Lists

1. First ordered item
2. Second ordered item
   - Nested unordered
   - Another nested
3. Third ordered item

- Unordered item 1
- Unordered item 2
  1. Nested ordered
  2. Another nested ordered
- Unordered item 3

## Links and References

Check out [Rust Programming Language](https://rust-lang.org) for more information.
Also see [GitHub](https://github.com) for code hosting.

### More Content

Sed ut perspiciatis unde omnis iste natus error sit voluptatem accusantium doloremque laudantium,
totam rem aperiam, eaque ipsa quae ab illo inventore veritatis et quasi architecto beatae vitae
dicta sunt explicabo.
"#;

fn generate_large_md() -> String {
    let mut content = String::from("# Large Test Document\n\n");

    // Add 100 sections with various content
    for i in 0..100 {
        content.push_str(&format!("\n## Section {}\n\n", i));
        content.push_str(&format!(
            "This is paragraph {} with **bold** and *italic* text.\n\n",
            i
        ));

        if i % 3 == 0 {
            content.push_str("```rust\n");
            content.push_str(&format!("fn function_{}() {{\n", i));
            content.push_str("    // Some code here\n");
            content.push_str("}\n```\n\n");
        }

        if i % 5 == 0 {
            content.push_str("| Col1 | Col2 | Col3 |\n");
            content.push_str("|------|------|------|\n");
            content.push_str(&format!("| A{}  | B{}  | C{}  |\n\n", i, i, i));
        }

        if i % 7 == 0 {
            content.push_str("- List item 1\n");
            content.push_str("  - Nested item\n");
            content.push_str("- List item 2\n\n");
        }
    }

    content
}

fn benchmark_renderer_standard(c: &mut Criterion) {
    let mut group = c.benchmark_group("renderer_standard");

    group.bench_function("small", |b| {
        b.iter(|| {
            let _widget = RendererStandard::new(black_box(SMALL_MD.to_string()));
        });
    });

    group.bench_function("medium", |b| {
        b.iter(|| {
            let _widget = RendererStandard::new(black_box(MEDIUM_MD.to_string()));
        });
    });

    let large_md = generate_large_md();
    group.bench_function("large", |b| {
        b.iter(|| {
            let _widget = RendererStandard::new(black_box(large_md.clone()));
        });
    });

    group.finish();
}

fn benchmark_renderer_optimized(c: &mut Criterion) {
    let mut group = c.benchmark_group("renderer_optimized");

    group.bench_function("small", |b| {
        b.iter(|| {
            let _widget = RendererOptimized::new(black_box(SMALL_MD.to_string()));
        });
    });

    group.bench_function("medium", |b| {
        b.iter(|| {
            let _widget = RendererOptimized::new(black_box(MEDIUM_MD.to_string()));
        });
    });

    let large_md = generate_large_md();
    group.bench_function("large", |b| {
        b.iter(|| {
            let _widget = RendererOptimized::new(black_box(large_md.clone()));
        });
    });

    group.finish();
}

fn benchmark_comparison(c: &mut Criterion) {
    let mut group = c.benchmark_group("renderer_comparison");

    for (name, content) in &[
        ("small", SMALL_MD.to_string()),
        ("medium", MEDIUM_MD.to_string()),
        ("large", generate_large_md()),
    ] {
        group.bench_with_input(BenchmarkId::new("standard", name), content, |b, content| {
            b.iter(|| {
                let _widget = RendererStandard::new(black_box(content.clone()));
            });
        });

        group.bench_with_input(
            BenchmarkId::new("optimized", name),
            content,
            |b, content| {
                b.iter(|| {
                    let _widget = RendererOptimized::new(black_box(content.clone()));
                });
            },
        );
    }

    group.finish();
}

criterion_group!(
    benches,
    benchmark_renderer_standard,
    benchmark_renderer_optimized,
    benchmark_comparison
);
criterion_main!(benches);
