# Skill Template

Use this template as a starting point for new skills.

## Usage

1. Copy this template to `.claude/skills/[your-skill-name]/SKILL.md`
2. Replace all `[PLACEHOLDERS]` with your content
3. Remove sections that don't apply
4. Add domain-specific content

---

## Template

```markdown
---
name: [skill-name]
description: [What this skill does]. Use when [trigger conditions]. Handles [specific tasks like X, Y, Z].
---

# [Skill Title]

## Overview

[1-2 sentences describing what this skill accomplishes and why it exists.]

## Quick Start

[Minimal steps to use this skill immediately - the 80% use case.]

1. [Step 1]
2. [Step 2]
3. [Step 3]

## Core Instructions

### [Main Workflow Section]

[Primary instructions for the most common use case.]

### [Secondary Workflow Section]

[Instructions for alternative or advanced use cases.]

## Tool Usage

[Specify which tools to use and how.]

| Task | Tool | Notes |
|------|------|-------|
| [Task 1] | [Tool] | [Usage notes] |
| [Task 2] | [Tool] | [Usage notes] |

## Output Format

[Describe expected output format if applicable.]

```
[Example output structure]
```

## Anti-Patterns

[What NOT to do - common mistakes to avoid.]

- **Don't**: [Anti-pattern 1]
- **Don't**: [Anti-pattern 2]
- **Instead**: [Correct approach]

## Additional Resources

- [Reference 1](references/[file1].md) - [Description]
- [Reference 2](references/[file2].md) - [Description]

## Examples

### Example 1: [Scenario Name]

**Input**: [What the user asks]

**Process**:
1. [Step 1]
2. [Step 2]

**Output**: [Expected result]
```

---

## Frontmatter Options

Add these optional fields as needed:

```yaml
---
name: skill-name
description: Description here

# Add if restricting tools
allowed-tools:
  - Read
  - Grep
  - Bash(python:*)

# Add if running in isolated context
context: fork
agent: general-purpose

# Add if hiding from slash menu
user-invocable: false

# Add for documentation
license: MIT
compatibility: Requires Python 3.8+
metadata:
  author: your-name
  version: "1.0"
---
```

---

## Checklist Before Using

- [ ] Replaced all `[PLACEHOLDERS]`
- [ ] Directory name matches `name` field
- [ ] Description is specific with trigger terms
- [ ] Removed unused sections
- [ ] Tested activation with relevant prompt
