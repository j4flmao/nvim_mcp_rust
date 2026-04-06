// src/markdown.rs — render markdown to UI format

use pulldown_cmark::{CodeBlockKind, Event, Options, Parser, Tag, TagEnd};

pub fn render_to_ui(markdown: String) -> String {
    let mut output = String::new();
    let mut in_code_block = false;

    let parser = Parser::new_ext(&markdown, Options::all());

    let events: Vec<Event> = parser.collect();

    for event in events {
        match event {
            Event::Start(Tag::CodeBlock(kind)) => {
                in_code_block = true;
                let lang = match kind {
                    CodeBlockKind::Fenced(l) => l.to_string(),
                    CodeBlockKind::Indented => String::new(),
                };
                output.push_str("\n┌─ ");
                if !lang.is_empty() {
                    output.push_str(&lang);
                } else {
                    output.push_str("code");
                }
                output.push_str(" ─\n");
            }

            Event::End(TagEnd::CodeBlock) => {
                in_code_block = false;
                output.push_str("\n└─────────────────\n");
            }

            Event::Text(text) => {
                if in_code_block {
                    for line in text.lines() {
                        output.push_str("  ");
                        output.push_str(line);
                        output.push('\n');
                    }
                } else {
                    output.push_str(&text);
                }
            }

            Event::SoftBreak => {
                output.push('\n');
            }

            Event::HardBreak => {
                output.push_str("\n\n");
            }

            _ => {}
        }
    }

    let result = output.trim().to_string();

    render_markdown_table(&result)
}

fn render_markdown_table(text: &str) -> String {
    let lines: Vec<&str> = text.lines().collect();
    let mut output = Vec::new();
    let mut i = 0;

    while i < lines.len() {
        let line = lines[i].trim();

        if line.starts_with('|') && !line.contains("---") {
            let mut rows = Vec::new();
            let mut col_widths = Vec::new();
            let start_idx = i;

            while i < lines.len() {
                let row_line = lines[i].trim();
                if !row_line.starts_with('|') || row_line.contains("---") {
                    break;
                }

                let cells: Vec<&str> = row_line
                    .split('|')
                    .filter(|s| !s.trim().is_empty())
                    .map(|s| s.trim())
                    .collect();

                if !cells.is_empty() {
                    if rows.is_empty() {
                        col_widths.resize(cells.len(), 0);
                    }

                    for (j, cell) in cells.iter().enumerate() {
                        if j < col_widths.len() {
                            col_widths[j] = col_widths[j].max(cell.len());
                        }
                    }
                    rows.push(cells);
                }
                i += 1;
            }

            if !rows.is_empty() && col_widths.len() > 1 {
                for (ri, row) in rows.iter().enumerate() {
                    let mut line = String::from("│ ");
                    for (j, cell) in row.iter().enumerate() {
                        if j > 0 {
                            line.push_str(" │ ");
                        }
                        let width = col_widths.get(j).copied().unwrap_or(cell.len());
                        line.push_str(cell);
                        line.push_str(&" ".repeat(width.saturating_sub(cell.len())));
                    }
                    line.push_str(" │");
                    output.push(line);

                    if ri == 0 {
                        let sep: String = col_widths
                            .iter()
                            .enumerate()
                            .map(|(j, w)| {
                                if j == 0 {
                                    format!("├─{}─", "-".repeat(*w))
                                } else {
                                    format!("┼{}─", "-".repeat(*w))
                                }
                            })
                            .collect();
                        output.push(sep);
                    }
                }
            } else {
                for line in &lines[start_idx..i] {
                    output.push(line.to_string());
                }
            }
        } else {
            output.push(line.to_string());
            i += 1;
        }
    }

    output.join("\n")
}
