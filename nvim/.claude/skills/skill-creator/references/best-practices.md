# Skill Authoring Best Practices

Comprehensive best practices compiled from official documentation, community examples, and real-world usage.

---

## Core Philosophy

### Context Window is a Public Good

Every token in a skill competes with:
- Conversation history
- Code being analyzed
- Tool outputs

**Principle**: Only include information that fills genuine gaps in Claude's knowledge.

### Progressive Disclosure

Load content in stages:

```
Startup: name + description (~100 tokens)
    ↓
Activation: SKILL.md body (<5000 tokens)
    ↓
On-demand: references/* (unlimited)
```

**Principle**: Keep the hot path minimal.

### Freedom Level Matching

Match instruction specificity to task fragility:

| Task Type | Freedom | Format |
|-----------|---------|--------|
| Creative exploration | High | Principles, guidelines |
| Standard workflows | Medium | Pseudocode, examples |
| Fragile operations | Low | Exact commands, strict steps |

---

## Writing Effective Content

### Description Best Practices

1. **Include WHAT and WHEN**
   ```yaml
   # Good
   description: Extract text from PDFs. Use when working with PDF files.

   # Bad
   description: PDF helper
   ```

2. **Add trigger keywords**
   - File extensions (`.pdf`, `.xlsx`)
   - Action verbs (extract, generate, create)
   - Domain terms (forms, spreadsheets)

3. **Be specific to avoid false matches**
   ```yaml
   # Too broad - triggers on unrelated requests
   description: Helps analyze data

   # Specific - triggers correctly
   description: Analyze sales data in Excel files and CRM exports
   ```

4. **Stay under 1024 characters**

### Instruction Writing

1. **Be actionable**
   ```markdown
   # Good
   1. Run `git diff --staged` to see changes
   2. Write commit message under 50 chars

   # Bad
   Think about what changed and write a good message
   ```

2. **Use structured formats**
   - Numbered steps for sequences
   - Tables for reference data
   - Code blocks for commands
   - Bullet points for options

3. **Provide context for decisions**
   ```markdown
   # Good
   Use pandas for data analysis (faster for large datasets)
   Use openpyxl for formatting (preserves Excel features)

   # Bad
   Use pandas or openpyxl as needed
   ```

4. **Include examples**
   ```markdown
   ## Example: Simple extraction
   Input: sales_report.pdf
   Command: `python extract.py sales_report.pdf`
   Output: sales_report.txt with extracted text
   ```

### Anti-Pattern Documentation

Always document what NOT to do:

```markdown
## Anti-Patterns

- **Don't** use hardcoded values for formulas (use Excel formulas instead)
- **Don't** modify XML directly without validation
- **Don't** skip the verification step

**Instead**:
- Use dynamic formulas
- Validate after every XML edit
- Always verify output before returning
```

---

## File Organization

### Directory Structure Guidelines

```
skill-name/
├── SKILL.md           # <500 lines, core instructions
├── references/        # Detailed documentation
│   ├── api.md         # API reference
│   ├── examples.md    # Usage examples
│   └── troubleshooting.md
├── templates/         # Reusable patterns
│   └── output-format.md
└── scripts/           # Executable utilities
    └── validate.py
```

### When to Split Content

Move content to references when:
- Section exceeds 100 lines
- Content is only needed for specific sub-tasks
- Content is reference material (tables, lists)
- Content is examples or tutorials

### Reference File Guidelines

1. **Self-contained**: Each file should be useful standalone
2. **Focused**: One topic per file
3. **Linked**: Cross-reference related files
4. **Discoverable**: Clear, descriptive filenames

---

## Tool Usage Patterns

### When to Restrict Tools

Use `allowed-tools` when:
- Skill should be read-only
- Specific tool subset is required
- Security constraints apply

```yaml
# Read-only analysis
allowed-tools: Read, Grep, Glob

# Python scripting only
allowed-tools: Read, Write, Bash(python:*)
```

### Tool Instruction Patterns

1. **Specify the right tool for each task**
   ```markdown
   | Task | Tool |
   |------|------|
   | Search code | Grep |
   | Read file | Read |
   | Execute script | Bash |
   ```

2. **Provide exact commands**
   ```markdown
   Extract text:
   ```bash
   python scripts/extract.py input.pdf -o output.txt
   ```
   ```

3. **Include validation steps**
   ```markdown
   After editing:
   1. Run `python validate.py output.xlsx`
   2. Check for errors in output
   3. Verify formulas calculate correctly
   ```

---

## Subagent Orchestration

### When to Use Subagents

- **Parallel research**: Multiple independent information sources
- **Context isolation**: Exploration that shouldn't pollute main context
- **Specialized work**: Tasks requiring different tool sets
- **Large scope**: Tasks that would consume too much main context

### Subagent Guidelines

1. **One goal per subagent**
   ```markdown
   # Good
   "Analyze authentication flow and list all entry points"

   # Bad
   "Look at auth, fix bugs, write tests, update docs"
   ```

2. **Narrow tool scope**
   - Research: Read, Grep, Glob
   - Web: WebFetch, WebSearch
   - Build: Read, Write, Edit, Bash

3. **Clear output expectations**
   ```markdown
   Return:
   - List of files containing auth logic
   - Summary of authentication flow
   - Identified security concerns
   ```

### Parallel vs Sequential

| Use Parallel When | Use Sequential When |
|-------------------|---------------------|
| Tasks are independent | Tasks have dependencies |
| No shared resources | Output of A feeds into B |
| Time is critical | Order matters |

---

## Quality Standards

### Output Verification

Always include verification steps:

```markdown
## Verification

After completion:
1. [ ] All files created/modified
2. [ ] No syntax errors
3. [ ] Tests pass (if applicable)
4. [ ] Output matches expected format
```

### Error Handling

Document common errors and fixes:

```markdown
## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| File not found | Wrong path | Use absolute path |
| Permission denied | Not executable | `chmod +x script.sh` |
| Import error | Missing dependency | `pip install package` |
```

### Iteration Guidance

Skills improve through observation:

1. **Watch activation patterns**
   - Does it trigger correctly?
   - Does it miss relevant requests?
   - Does it trigger incorrectly?

2. **Monitor instruction following**
   - Are instructions clear?
   - Is anything consistently skipped?
   - Are there common mistakes?

3. **Refine based on data**
   - Adjust trigger terms
   - Clarify confusing instructions
   - Add missing guidance

---

## Security Considerations

### Tool Restrictions

Apply minimum necessary permissions:

```yaml
# Principle of least privilege
allowed-tools:
  - Read           # Can read any file
  - Grep           # Can search
  - Bash(git:*)    # Only git commands
```

### Sensitive Data

- Never include credentials in skills
- Use environment variables for secrets
- Warn about sensitive file types

### Validation Hooks

Use hooks for security-sensitive operations:

```yaml
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "./scripts/validate-command.sh"
```

---

## Performance Optimization

### Context Efficiency

1. **Keep SKILL.md under 500 lines**
2. **Move details to references**
3. **Use tables instead of prose**
4. **Avoid redundant explanations**

### Script Efficiency

Scripts are more efficient than generated code:
- Script source never loads into context
- Only script output consumes tokens
- Reusable across conversations

### Loading Strategy

```
Minimum viable context:
├── Description (triggers activation)
├── Quick start (common case)
└── Reference links (uncommon cases)

Load on demand:
├── Detailed API docs
├── Extended examples
└── Troubleshooting guides
```

---

## Maintenance

### Version Control

- Commit working versions before changes
- Document significant updates
- Test after modifications

### Documentation

- Keep README if skill is shared
- Document dependencies
- Note compatibility requirements

### Deprecation

When retiring a skill:
1. Update description to indicate deprecation
2. Point to replacement skill
3. Remove after transition period
