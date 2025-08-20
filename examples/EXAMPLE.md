# Markdown Preview Example

This document demonstrates all Markdown elements supported by the terminal preview tool.

## Text Formatting

### Basic Formatting

This is **bold text** and this is *italic text*. You can also use `inline code` and combine ***bold and italic*** formatting.

You can also use ~~strikethrough text~~ when needed.

### Line Breaks

This is the first line.  
This is the second line with a hard break.

This is a new paragraph after a blank line.

## Headings

# Heading Level 1
## Heading Level 2
### Heading Level 3
#### Heading Level 4
##### Heading Level 5
###### Heading Level 6

## Blockquotes

> This is a blockquote.
> It can span multiple lines.
> 
> > You can also nest blockquotes.
> > > And even deeper nesting is possible.
> 
> Back to the first level.

## Lists

### Unordered Lists

- First item
- Second item
  - Nested item 2.1
  - Nested item 2.2
    - Deep nested item
- Third item

### Ordered Lists

1. First ordered item
2. Second ordered item
   1. Nested ordered item
   2. Another nested item
3. Third ordered item

### Mixed Lists

1. First ordered item
   - Unordered sub-item
   - Another unordered sub-item
2. Second ordered item
   1. Ordered sub-item
   2. Another ordered sub-item

## Links

[This is an inline link](https://github.com)

[This is a link with title](https://github.com "GitHub Homepage")

This is a reference-style link to [GitHub][1].

[1]: https://github.com

## Code

### Inline Code

Use `git status` to check your repository status.

### Code Blocks

```rust
// Rust code example
fn main() {
    println!("Hello, Markdown Preview!");
    
    let numbers = vec![1, 2, 3, 4, 5];
    for num in numbers {
        println!("Number: {}", num);
    }
}
```

```python
# Python code example
def fibonacci(n):
    """Generate Fibonacci sequence"""
    if n <= 0:
        return []
    elif n == 1:
        return [0]
    elif n == 2:
        return [0, 1]
    
    fib = [0, 1]
    for i in range(2, n):
        fib.append(fib[-1] + fib[-2])
    return fib

print(fibonacci(10))
```

```javascript
// JavaScript code example
const fetchData = async (url) => {
    try {
        const response = await fetch(url);
        const data = await response.json();
        console.log('Data received:', data);
        return data;
    } catch (error) {
        console.error('Error fetching data:', error);
    }
};

fetchData('https://api.example.com/data');
```

```bash
#!/bin/bash
# Bash script example

echo "Starting deployment..."

# Build the project
cargo build --release

# Run tests
cargo test

# Deploy
if [ $? -eq 0 ]; then
    echo "Tests passed. Deploying..."
    ./deploy.sh
else
    echo "Tests failed. Aborting deployment."
    exit 1
fi
```

### Code Block without Language

```
This is a code block without syntax highlighting.
It can contain any text format.
    Including indented lines.
```

## Tables

### Simple Table

| Column 1 | Column 2 | Column 3 |
|----------|----------|----------|
| Data 1   | Data 2   | Data 3   |
| Data 4   | Data 5   | Data 6   |

### Table with Alignment

| Left Aligned | Center Aligned | Right Aligned |
|:-------------|:--------------:|--------------:|
| Left         | Center         | Right         |
| 123          | 456            | 789           |
| Lorem        | Ipsum          | Dolor         |

### Complex Table

| Feature | Description | Status | Priority |
|---------|-------------|--------|----------|
| **TUI Mode** | Terminal UI with file tree and preview | ✅ Complete | High |
| **Syntax Highlighting** | Color coding for different Markdown elements | ✅ Complete | High |
| **Tables** | Support for rendering tables | ✅ Complete | Medium |
| **Code Blocks** | Syntax highlighted code blocks | ✅ Complete | High |
| **Lists** | Nested lists support | ✅ Complete | Medium |
| **Links** | Clickable links in terminal | 🚧 In Progress | Low |
| **Images** | ASCII art representation | ❌ Not Started | Low |

## Horizontal Rules

---

***

___

## HTML Entities

Common HTML entities: &copy; &reg; &trade; &nbsp; &amp; &lt; &gt; &quot;

Mathematical symbols: &alpha; &beta; &gamma; &delta; &pi; &sum; &infin;

## Special Characters

Escaping special characters: \* \_ \[ \] \( \) \# \+ \- \. \!

## Task Lists

- [x] Completed task
- [x] Another completed task
- [ ] Incomplete task
- [ ] Another incomplete task
  - [x] Completed subtask
  - [ ] Incomplete subtask

## Emoji Support

Some terminals support emoji: 🚀 ✨ 🎉 💻 📝 ✅ ❌ 🔧 📚

## Long Content for Scrolling Test

Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.

Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.

### Section 1: Architecture Overview

The application is built using Rust and leverages several key libraries:

- **Ratatui**: Terminal UI framework
- **pulldown-cmark**: Markdown parser
- **crossterm**: Terminal manipulation
- **clap**: Command-line argument parsing

### Section 2: Performance Optimizations

1. **Caching Strategy**: Pre-parse Markdown content and cache the rendered widgets
2. **Event-Driven Rendering**: Only redraw when user input is detected
3. **Virtual Scrolling**: Render only visible portions of the content
4. **Lazy Loading**: Load files on demand rather than all at once

### Section 3: Features

#### Core Features

- Fast Markdown parsing and rendering
- Syntax highlighting with customizable themes
- File tree navigation
- Keyboard shortcuts for efficient navigation
- Support for all major Markdown elements

#### Advanced Features

- Multiple viewing modes (stdout, TUI)
- Theme customization
- Plugin system for extensions
- Export to various formats

### Section 4: Usage Examples

```bash
# Basic usage
mp README.md

# TUI mode
mp --tui

# With custom theme
mp --theme dark README.md

# Multiple files
mp *.md
```

### Section 5: Contributing

We welcome contributions! Please follow these guidelines:

1. Fork the repository
2. Create a feature branch
3. Write tests for new features
4. Ensure all tests pass
5. Submit a pull request

### Section 6: License

This project is licensed under the MIT License. See the LICENSE file for details.

---

## Performance Test Content

The following sections are repeated content for testing scrolling performance:

### Test Section 1

Lorem ipsum dolor sit amet, consectetur adipiscing elit. Vestibulum euismod, nisl eget ultricies tincidunt, nunc nisl aliquam nunc, eget aliquam nunc nisl eget nunc.

```rust
fn test_function_1() {
    for i in 0..100 {
        println!("Iteration: {}", i);
    }
}
```

| Test | Value | Result |
|------|-------|--------|
| A    | 100   | Pass   |
| B    | 200   | Pass   |
| C    | 300   | Fail   |

### Test Section 2

Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris.

```python
def test_function_2():
    for i in range(100):
        print(f"Iteration: {i}")
```

- List item 1
- List item 2
  - Nested item 2.1
  - Nested item 2.2
- List item 3

### Test Section 3

Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur.

> Important quote about software development.
> It spans multiple lines for emphasis.

### Test Section 4

Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.

1. Ordered item 1
2. Ordered item 2
3. Ordered item 3
   1. Nested ordered item
   2. Another nested item

### Test Section 5

Lorem ipsum dolor sit amet, consectetur adipiscing elit. Vestibulum euismod, nisl eget ultricies tincidunt.

**Bold text** and *italic text* and ***bold italic text*** for testing rendering.

### Test Section 6

```javascript
function testFunction6() {
    const items = [1, 2, 3, 4, 5];
    items.forEach(item => {
        console.log(`Item: ${item}`);
    });
}
```

### Test Section 7

| Header 1 | Header 2 | Header 3 | Header 4 |
|----------|----------|----------|----------|
| Cell 1   | Cell 2   | Cell 3   | Cell 4   |
| Cell 5   | Cell 6   | Cell 7   | Cell 8   |
| Cell 9   | Cell 10  | Cell 11  | Cell 12  |

### Test Section 8

- [ ] Task 1
- [x] Task 2
- [ ] Task 3
- [x] Task 4

### Test Section 9

This section contains `inline code` examples and more text to test scrolling performance with various Markdown elements.

### Test Section 10

Final section with mixed content:

1. **Bold ordered item**
2. *Italic ordered item*
3. `Code ordered item`

> Blockquote at the end
> With multiple lines
> For testing purposes

---

## End of Document

This marks the end of the Markdown preview example document. Thank you for testing!